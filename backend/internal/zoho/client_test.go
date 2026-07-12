package zoho

import "testing"

func TestParticipantURL(t *testing.T) {
	t.Parallel()

	got := ParticipantURL("https://meeting.zoho.in/meeting/register/join?registerKey=secret%2Bkey&sessionId=1234567890&uname=Kalyan+R&ignored=value")
	want := "https://meeting.zoho.in/meeting/webinar-participant.do?key=1234567890&registerKey=secret%2Bkey&uname=Kalyan+R"
	if got != want {
		t.Fatalf("ParticipantURL() = %q, want %q", got, want)
	}
}

func TestParticipantURLLeavesUnknownLinksAlone(t *testing.T) {
	t.Parallel()

	links := []string{
		"https://meeting.zoho.in/meeting/register/join?sessionId=123",
		"https://example.com/meeting",
		"not a url",
	}
	for _, link := range links {
		if got := ParticipantURL(link); got != link {
			t.Errorf("ParticipantURL(%q) = %q, want unchanged", link, got)
		}
	}
}
