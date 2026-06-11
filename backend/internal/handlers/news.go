package handlers

import (
	"context"
	"encoding/xml"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gofiber/fiber/v2"
)

// ---------------------------------------------------------------------------
// Live AI / tech news aggregator.
//
// Pulls headlines from public RSS/Atom feeds server-side (no CORS, no API keys),
// merges + sorts them newest-first, and caches the result with a short TTL so
// the per-request latency stays near zero. The client polls /api/v1/news every
// few minutes; the cache serves stale data instantly while refreshing in the
// background (stale-while-revalidate).
//
// Only the headline, source name, published time and a link back to the
// original article are exposed — no article bodies — keeping usage within the
// bounds of fair RSS syndication.
//
// New categories (cybersecurity, cloud, startups, coding …) are a one-line
// addition to `newsFeeds`; the ?category= query filters on the Category tag.
// ---------------------------------------------------------------------------

type newsFeed struct {
	Source   string
	URL      string
	Category string // ai | tech | (future: cybersecurity, cloud, startups, coding)
}

// Curated, reliable public feeds (all verified to return real RSS/Atom). Vendor
// blogs first, then AI press. Dead/empty feeds are skipped gracefully, so this
// list can grow freely.
var newsFeeds = []newsFeed{
	{"OpenAI", "https://openai.com/news/rss.xml", "ai"},
	{"Google DeepMind", "https://deepmind.google/blog/rss.xml", "ai"},
	{"Microsoft", "https://news.microsoft.com/source/feed/", "ai"},
	{"Azure AI", "https://azure.microsoft.com/en-us/blog/feed/", "ai"},
	{"NVIDIA AI", "https://blogs.nvidia.com/feed/", "ai"},
	{"Meta AI", "https://engineering.fb.com/feed/", "ai"},
	{"AWS Machine Learning", "https://aws.amazon.com/blogs/machine-learning/feed/", "ai"},
	{"TechCrunch AI", "https://techcrunch.com/category/artificial-intelligence/feed/", "tech"},
	{"The Verge AI", "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml", "tech"},
	{"VentureBeat AI", "https://venturebeat.com/category/ai/feed/", "tech"},
	{"Ars Technica AI", "https://arstechnica.com/ai/feed/", "tech"},
	{"MIT Tech Review", "https://www.technologyreview.com/topic/artificial-intelligence/feed", "tech"},
}

// newsArticle is the shape returned to the client.
type newsArticle struct {
	Title       string    `json:"title"`
	Source      string    `json:"source"`
	URL         string    `json:"url"`
	Category    string    `json:"category"`
	PublishedAt time.Time `json:"published_at"`
}

const (
	newsTTL     = 4 * time.Minute // cache freshness window
	newsLimit   = 50              // max headlines kept
	newsTimeout = 6 * time.Second // per-feed fetch budget
)

var newsHTTP = &http.Client{Timeout: newsTimeout}

// newsStore is a tiny in-memory cache with stale-while-revalidate semantics.
type newsStore struct {
	mu       sync.Mutex
	items    []newsArticle
	fetched  time.Time
	fetching bool
}

var newsCache = &newsStore{}

// get returns the cached articles for a category, refreshing as needed. A cold
// cache blocks until the first fetch completes; a stale cache is served
// immediately while a single background refresh runs.
func (s *newsStore) get(ctx context.Context, category string) []newsArticle {
	s.mu.Lock()
	fresh := len(s.items) > 0 && time.Since(s.fetched) < newsTTL
	if fresh {
		items := s.items
		s.mu.Unlock()
		return filterNews(items, category)
	}
	if len(s.items) > 0 { // stale: serve now, refresh once in the background
		if !s.fetching {
			s.fetching = true
			go s.refresh()
		}
		items := s.items
		s.mu.Unlock()
		return filterNews(items, category)
	}
	s.mu.Unlock()

	// Cold cache — fetch synchronously so the first caller gets real data.
	items := fetchAllFeeds(ctx)
	s.mu.Lock()
	if len(items) > 0 {
		s.items = items
		s.fetched = time.Now()
	}
	out := s.items
	s.mu.Unlock()
	return filterNews(out, category)
}

func (s *newsStore) refresh() {
	ctx, cancel := context.WithTimeout(context.Background(), 2*newsTimeout)
	defer cancel()
	items := fetchAllFeeds(ctx)
	s.mu.Lock()
	if len(items) > 0 {
		s.items = items
		s.fetched = time.Now()
	}
	s.fetching = false
	s.mu.Unlock()
}

func filterNews(items []newsArticle, category string) []newsArticle {
	if category == "" || category == "all" {
		return items
	}
	out := make([]newsArticle, 0, len(items))
	for _, it := range items {
		if it.Category == category {
			out = append(out, it)
		}
	}
	// If a category has no dedicated feeds yet, fall back to everything so the
	// panel is never empty.
	if len(out) == 0 {
		return items
	}
	return out
}

// fetchAllFeeds pulls every feed concurrently, merges, dedups and sorts.
func fetchAllFeeds(ctx context.Context) []newsArticle {
	var (
		wg   sync.WaitGroup
		mu   sync.Mutex
		all  []newsArticle
		seen = map[string]bool{}
	)
	for _, f := range newsFeeds {
		wg.Add(1)
		go func(f newsFeed) {
			defer wg.Done()
			arts := fetchFeed(ctx, f)
			mu.Lock()
			for _, a := range arts {
				if a.URL == "" || seen[a.URL] {
					continue
				}
				seen[a.URL] = true
				all = append(all, a)
			}
			mu.Unlock()
		}(f)
	}
	wg.Wait()

	sort.Slice(all, func(i, j int) bool { return all[i].PublishedAt.After(all[j].PublishedAt) })
	if len(all) > newsLimit {
		all = all[:newsLimit]
	}
	return all
}

// rss / atom container — one struct parses both formats.
type xmlFeed struct {
	// RSS 2.0
	Items []struct {
		Title   string `xml:"title"`
		Link    string `xml:"link"`
		PubDate string `xml:"pubDate"`
		DCDate  string `xml:"date"` // dc:date
	} `xml:"channel>item"`
	// Atom
	Entries []struct {
		Title string `xml:"title"`
		Links []struct {
			Href string `xml:"href,attr"`
			Rel  string `xml:"rel,attr"`
		} `xml:"link"`
		Published string `xml:"published"`
		Updated   string `xml:"updated"`
	} `xml:"entry"`
}

func fetchFeed(ctx context.Context, f newsFeed) []newsArticle {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, f.URL, nil)
	if err != nil {
		return nil
	}
	// A browser-like UA + Accept keeps picky CDNs from returning 403/410.
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36")
	req.Header.Set("Accept", "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.8")
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")

	resp, err := newsHTTP.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20)) // 4 MB cap
	if err != nil {
		return nil
	}

	var feed xmlFeed
	if err := xml.Unmarshal(body, &feed); err != nil {
		return nil
	}

	var out []newsArticle
	for _, it := range feed.Items { // RSS
		title := cleanText(it.Title)
		if title == "" || it.Link == "" {
			continue
		}
		out = append(out, newsArticle{
			Title:       title,
			Source:      f.Source,
			URL:         strings.TrimSpace(it.Link),
			Category:    f.Category,
			PublishedAt: parseFeedTime(it.PubDate, it.DCDate),
		})
	}
	for _, e := range feed.Entries { // Atom
		title := cleanText(e.Title)
		link := atomLink(e.Links)
		if title == "" || link == "" {
			continue
		}
		out = append(out, newsArticle{
			Title:       title,
			Source:      f.Source,
			URL:         link,
			Category:    f.Category,
			PublishedAt: parseFeedTime(e.Published, e.Updated),
		})
	}
	return out
}

// atomLink prefers the rel="alternate" (or rel-less) link to the article.
func atomLink(links []struct {
	Href string `xml:"href,attr"`
	Rel  string `xml:"rel,attr"`
}) string {
	for _, l := range links {
		if l.Rel == "alternate" || l.Rel == "" {
			return strings.TrimSpace(l.Href)
		}
	}
	if len(links) > 0 {
		return strings.TrimSpace(links[0].Href)
	}
	return ""
}

func cleanText(s string) string {
	s = strings.TrimSpace(s)
	// xml.Unmarshal already resolves CDATA + standard entities; collapse stray
	// whitespace/newlines that some feeds wrap titles in.
	return strings.Join(strings.Fields(s), " ")
}

// parseFeedTime tries the common RSS/Atom date layouts, newest field first.
func parseFeedTime(candidates ...string) time.Time {
	layouts := []string{
		time.RFC1123Z,
		time.RFC1123,
		time.RFC3339,
		"Mon, 2 Jan 2006 15:04:05 -0700",
		"Mon, 02 Jan 2006 15:04:05 MST",
		"2006-01-02T15:04:05Z07:00",
		"2006-01-02 15:04:05",
		"2006-01-02",
	}
	for _, c := range candidates {
		c = strings.TrimSpace(c)
		if c == "" {
			continue
		}
		for _, l := range layouts {
			if t, err := time.Parse(l, c); err == nil {
				return t.UTC()
			}
		}
	}
	// Unknown/missing date: treat as "now" so it isn't buried at the bottom.
	return time.Now().UTC()
}

// News serves aggregated live headlines. Public, cacheable, read-only.
//
//	GET /api/v1/news?category=ai
func (h *Handlers) News(c *fiber.Ctx) error {
	category := strings.ToLower(strings.TrimSpace(c.Query("category", "ai")))
	ctx, cancel := context.WithTimeout(c.Context(), 2*newsTimeout)
	defer cancel()

	items := newsCache.get(ctx, category)

	// Let browsers/proxies hold the response briefly without hammering us.
	c.Set("Cache-Control", "public, max-age=120")
	return c.JSON(fiber.Map{
		"news":       items,
		"count":      len(items),
		"updated_at": time.Now().UTC(),
	})
}
