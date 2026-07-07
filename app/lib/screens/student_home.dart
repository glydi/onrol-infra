import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' hide Text;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;
import 'package:onrol_app/widgets/upper_text.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart' as appcfg;
import '../services/api_client.dart';
import '../services/auth_service.dart';
import 'package:file_picker/file_picker.dart';

import '../theme_controller.dart';
import '../services/tab_badge_stub.dart' if (dart.library.html) '../services/tab_badge_web.dart';
import '../widgets/download_stub.dart' if (dart.library.html) '../widgets/download_web.dart';
import '../widgets/markdown_view.dart';
import 'live_screen.dart';
import 'live_session_screen.dart';
import 'login_screen.dart';
import 'video_player_screen.dart';

// Palette — bright, lively orange accent.
const _orange = Color(0xFFFF5A1F);
// Shared accent gradient — a STRONG orange → deep-orange ramp (no soft peach),
// so buttons and accents read as a bold, saturated orange.
const _orangeGrad = LinearGradient(
  colors: [Color(0xFFFF6A2C), Color(0xFFF23E12)],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);
const _green = Color(0xFF2D8A4E);
const _greenBg = Color(0xFFEAFAF0);

// Brightness-aware palette. `_isDark` is set at the start of each build / dialog.
bool _isDark = false;
Color get _navy => _isDark ? const Color(0xFFECEDF2) : const Color(0xFF1A1A2E);
Color get _grey => _isDark ? const Color(0xFF9AA0AC) : const Color(0xFF888888);
Color get _peach => _isDark ? const Color(0xFF23252C) : const Color(0xFFF1F2F4); // neutral tint (no peach)
Color get _bg => _isDark ? const Color(0xFF0E0F14) : const Color(0xFFF4F5F7); // clean light grey (no peach)
Color get _surface => _isDark ? const Color(0xFF1E2027) : Colors.white;
Color get _line => _isDark ? const Color(0xFF2C2F37) : const Color(0xFFF0F0F0);

// ---- Glassmorphism --------------------------------------------------------
// Frosted translucent fill + hairline highlight border + soft drop shadow.
Color get _glassFill => _isDark ? const Color(0xFF1E2027).withOpacity(0.92) : Colors.white.withOpacity(0.92);
Color get _glassBorder => _isDark ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.65);
// Bright translucent card surface for elements inside popups — glassmorphic,
// no solid fill, so the frosted panel glows through every element.
Color get _cardBorder => _isDark ? Colors.white.withOpacity(0.10) : const Color(0xFFE6E7EB);
// Flat solid surface for element cards — a single tone (no ambient glow/gradient).
LinearGradient get _cardGradient => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: _isDark
          ? const [Color(0xFF1E2027), Color(0xFF1E2027)]
          : const [Colors.white, Colors.white],
    );

/// Wraps [child] in a frosted-glass surface (backdrop blur + translucent fill).
/// Use sparingly — each one is a real BackdropFilter.
Widget _glass({
  required Widget child,
  double radius = 0, // squared — no rounded corners
  EdgeInsetsGeometry? padding,
  double blur = 10, // gentler frost (less glassy)
  Color? tint,
  Color? border, // override the hairline border colour
  double borderWidth = 1,
}) {
  final r = BorderRadius.zero;
  return ClipRRect(
    borderRadius: r,
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: tint ?? _glassFill,
          borderRadius: r,
          border: Border.all(color: border ?? _glassBorder, width: borderWidth),
        ),
        child: child,
      ),
    ),
  );
}

/// A flat, tappable card with a thin border that highlights on hover (no glow).
/// Used for the home sidebar cards (profile, notifications, live news).
class _HoverCard extends StatefulWidget {
  const _HoverCard({required this.child, this.onTap, this.padding});
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;

  @override
  State<_HoverCard> createState() => _HoverCardState();
}

class _HoverCardState extends State<_HoverCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: _hover ? Color.alphaBlend(_orange.withOpacity(0.06), _surface) : _surface,
            border: Border.all(color: _hover ? _orange : _orange.withOpacity(0.28), width: _hover ? 1.4 : 1),
          ),
          child: Padding(padding: widget.padding ?? EdgeInsets.zero, child: widget.child),
        ),
      ),
    );
  }
}

/// How many panel/modal routes are currently open (used elsewhere to pause
/// background work while a popup is showing).
final ValueNotifier<int> _panelDepth = ValueNotifier(0);

/// Full-bleed backdrop — a flat, solid neutral fill. No peach, no gradient,
/// no blurred glow blobs (flat theme).
class _GlassBackdrop extends StatelessWidget {
  const _GlassBackdrop();

  @override
  Widget build(BuildContext context) => ColoredBox(color: _bg);
}

/// A default profile picture: an emoji on a gradient square (index 0 = the
/// user's initials instead of an emoji).
class _Avatar {
  const _Avatar(this.emoji, this.colors);
  final String emoji;
  final List<Color> colors;
}

const _avatars = <_Avatar>[
  _Avatar('', [_orange, Color(0xFFFF7A4D)]), // letter avatar
  _Avatar('🦊', [Color(0xFFFF8A3D), Color(0xFFFF5E3A)]),
  _Avatar('🐼', [Color(0xFF6A85F1), Color(0xFF8E54E9)]),
  _Avatar('🦁', [Color(0xFFFFB02E), Color(0xFFFF7A00)]),
  _Avatar('🐯', [Color(0xFFFF9A3E), Color(0xFFEF5A2A)]),
  _Avatar('🐨', [Color(0xFF8E9EAB), Color(0xFF5B6C82)]),
  _Avatar('🦉', [Color(0xFF36D1DC), Color(0xFF5B86E5)]),
  _Avatar('🐧', [Color(0xFF3A4A5E), Color(0xFF4B79A1)]),
  _Avatar('🚀', [Color(0xFFEE5A6F), Color(0xFFF29263)]),
  _Avatar('🐸', [Color(0xFF56AB2F), Color(0xFFA8E063)]),
];

/// Student home — a 5×5 orange checkerboard of options; each tile opens a modal
/// panel. Matches the ONROL "Learn. Grow. Succeed." mockup.
class StudentHome extends StatefulWidget {
  const StudentHome({super.key, required this.auth});
  final AuthService auth;

  @override
  State<StudentHome> createState() => _StudentHomeState();
}

class _Tile {
  const _Tile(this.icon, this.label, this.panel);
  final IconData icon;
  final String label;
  final String panel;
}

/// A headline in the "Live AI News" sidebar feed (static showcase content).
/// A live headline from the backend RSS aggregator (`/api/v1/news`).
class _News {
  _News({required this.title, required this.source, required this.url, this.publishedAt});
  final String title;
  final String source;
  final String url;
  final DateTime? publishedAt;

  factory _News.fromJson(Map<String, dynamic> j) => _News(
        title: j['title']?.toString() ?? '',
        source: j['source']?.toString() ?? '',
        url: j['url']?.toString() ?? '',
        publishedAt: DateTime.tryParse(j['published_at']?.toString() ?? '')?.toLocal(),
      );

  /// Recent enough (≤ 90 min) to carry the LIVE badge.
  bool get isLive {
    final p = publishedAt;
    return p != null && DateTime.now().difference(p) < const Duration(minutes: 90);
  }

  /// Relative "x min/hr/day ago" label.
  String get ago {
    final p = publishedAt;
    if (p == null) return '';
    final d = DateTime.now().difference(p);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} hr${d.inHours == 1 ? '' : 's'} ago';
    return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  }

  IconData get icon => _sourceIcon(source);
}

/// Per-source thumbnail glyph (keeps the existing icon-tile look).
IconData _sourceIcon(String source) {
  final s = source.toLowerCase();
  if (s.contains('openai')) return CupertinoIcons.sparkles;
  if (s.contains('nvidia')) return CupertinoIcons.bolt_fill;
  if (s.contains('meta')) return CupertinoIcons.layers_fill;
  if (s.contains('google') || s.contains('deepmind')) return CupertinoIcons.cube_box_fill;
  if (s.contains('microsoft')) return CupertinoIcons.square_grid_2x2_fill;
  if (s.contains('aws') || s.contains('amazon')) return CupertinoIcons.cloud_fill;
  if (s.contains('verge') || s.contains('techcrunch') || s.contains('venturebeat')) return CupertinoIcons.news_solid;
  return CupertinoIcons.wand_stars;
}

class _StudentHomeState extends State<StudentHome> {
  // 5×5 checkerboard: tiles sit on the (row+col)-odd cells, so the grid starts
  // with a blank at top-left and alternates. These 12 fill the active cells.
  static const List<_Tile> _tiles = [
    _Tile(CupertinoIcons.square_grid_2x2_fill, 'Dashboard', 'dashboard'),
    _Tile(CupertinoIcons.compass_fill, 'Explore', 'explore'),
    _Tile(CupertinoIcons.book_fill, 'My Courses', 'courses'),
    _Tile(CupertinoIcons.calendar, 'Schedule', 'schedule'),
    _Tile(CupertinoIcons.doc_text_fill, 'Assignments', 'assignments'),
    _Tile(CupertinoIcons.videocam_fill, 'Live Classes', 'live'),
    _Tile(CupertinoIcons.doc_richtext, 'Study Hub', 'study'),
    _Tile(CupertinoIcons.list_number, 'Leaderboard', 'leaderboard'),
    _Tile(CupertinoIcons.chat_bubble_2_fill, 'Ask Mentor', 'mentor'),
    _Tile(CupertinoIcons.square_pencil_fill, 'Notes', 'notes'),
    _Tile(CupertinoIcons.gear_alt_fill, 'Settings', 'settings'),
    _Tile(CupertinoIcons.square_arrow_right, 'Log Out', 'logout'),
  ];

  String get _name => widget.auth.user?.fullName ?? 'Student';
  String get _firstName => _name.split(RegExp(r'[\s@]')).first;

  // Day streak shown in the profile card — the real run of consecutive days the
  // learner completed a lesson (from /me/streak). Tapping opens Achievements.
  int _streak = 0;

  // The home is one scrollable column; this drives the floating scroll button.
  final ScrollController _homeScroll = ScrollController();
  bool _atBottom = false;
  bool _canScroll = false;

  // XP earned grows with progress: 10 XP per completed lesson.
  static int _xpFromCourses(List courses) => courses.fold<int>(
      0, (sum, c) => sum + (((c as Map)['lessons_done'] ?? 0) as num).toInt() * 10);

  @override
  void initState() {
    super.initState();
    _loadAvatarFromServer();
    _loadStreak();
    _homeScroll.addListener(_syncScrollState);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptDeviceName());
  }

  // On a login that bound a NEW device, ask the student to name it (one-shot).
  Future<void> _maybePromptDeviceName() async {
    final nd = widget.auth.newDevice;
    if (nd == null || !mounted) return;
    widget.auth.newDevice = null;
    final ctrl = TextEditingController();
    final hint = nd.cap > 0 ? 'Device ${nd.index} of ${nd.cap}' : 'New device';
    final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        title: const Text('Name this device'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$hint — give it a name so you (and your mentor) can recognise it later.', style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          TextField(controller: ctrl, autofocus: true, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'e.g. My phone', border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(null), child: const Text('Skip')),
          FilledButton(onPressed: () => Navigator.of(dctx).pop(ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      try {
        await widget.auth.apiPatch('/api/v1/devices/${nd.id}', {'name': name});
      } catch (_) {}
    }
  }

  // "My devices" — the student sees and renames the devices bound to their account.
  Widget _myDevicesSection() => _future(_apiList('/api/v1/devices', 'devices'), (List devices) {
        if (devices.isEmpty) return const SizedBox.shrink();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Align(alignment: Alignment.centerLeft, child: Text('My devices', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w800, color: _navy))),
          const SizedBox(height: 8),
          for (final d in devices) _deviceRow(d as Map<String, dynamic>),
        ]);
      });

  Widget _deviceRow(Map<String, dynamic> d) {
    final name = (d['name']?.toString().isNotEmpty ?? false)
        ? d['name'].toString()
        : (d['model']?.toString().isNotEmpty ?? false)
            ? d['model'].toString()
            : (d['platform']?.toString() ?? 'Device');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: _surface, border: Border.all(color: _cardBorder)),
      child: Row(children: [
        Icon(CupertinoIcons.device_phone_portrait, size: 18, color: _grey),
        const SizedBox(width: 10),
        Expanded(child: Text(name, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: _navy), maxLines: 1, overflow: TextOverflow.ellipsis)),
        _Pressable(onTap: () => _renameDevice(d), child: Padding(padding: const EdgeInsets.all(4), child: Icon(CupertinoIcons.pencil, size: 16, color: _orange))),
      ]),
    );
  }

  Future<void> _renameDevice(Map<String, dynamic> d) async {
    final ctrl = TextEditingController(text: d['name']?.toString() ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(controller: ctrl, autofocus: true, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'e.g. My phone', border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(null), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dctx).pop(ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name != null) {
      try {
        await widget.auth.apiPatch('/api/v1/devices/${d['id']}', {'name': name});
        if (mounted) setState(() {});
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _homeScroll.removeListener(_syncScrollState);
    _homeScroll.dispose();
    super.dispose();
  }

  // Keep the floating scroll button in sync: show it only when the page actually
  // scrolls, and flip its arrow at the bottom.
  void _syncScrollState() {
    if (!_homeScroll.hasClients) return;
    final pos = _homeScroll.position;
    final can = pos.maxScrollExtent > 12;
    final atB = pos.pixels >= pos.maxScrollExtent - 12;
    if (can != _canScroll || atB != _atBottom) {
      setState(() {
        _canScroll = can;
        _atBottom = atB;
      });
    }
  }

  // The floating "scroll" button the home shows when content runs off-screen
  // (e.g. the big matrix on iPad). Tapping jumps to the bottom, then back to top.
  Widget? _scrollFab() {
    if (!_canScroll) return null;
    return FloatingActionButton(
      backgroundColor: _orange,
      foregroundColor: Colors.white,
      onPressed: () {
        if (!_homeScroll.hasClients) return;
        final pos = _homeScroll.position;
        _homeScroll.animateTo(_atBottom ? 0.0 : pos.maxScrollExtent,
            duration: const Duration(milliseconds: 420), curve: Curves.easeInOutCubic);
      },
      child: Icon(_atBottom ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down),
    );
  }

  // Pull the real daily streak (consecutive days with a completed lesson).
  Future<void> _loadStreak() async {
    try {
      final m = ApiClient.decode(await widget.auth.apiGet('/api/v1/me/streak'));
      final s = ((m['streak'] ?? 0) as num).toInt();
      if (mounted) setState(() => _streak = s);
    } catch (_) {}
  }

  // Pull the saved profile picture from the backend (source of truth) and cache
  // it so the avatar is correct across devices.
  Future<void> _loadAvatarFromServer() async {
    try {
      final m = ApiClient.decode(await widget.auth.apiGet('/api/v1/me/profile'));
      await cacheAvatar(m['avatar']?.toString() ?? '');
    } catch (_) {}
  }

  // Persist a new avatar: cache + notifier immediately, then save to the DB.
  Future<void> _setAvatar(String v) async {
    await cacheAvatar(v);
    try {
      await widget.auth.apiPatch('/api/v1/me/profile', {'avatar': v});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't save picture — try again."), behavior: SnackBarBehavior.floating));
      }
    }
  }

  Future<void> _logout() async {
    await widget.auth.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth)));
  }

  // ---- Backend helpers -----------------------------------------------------

  Future<Map<String, dynamic>> _apiMap(String path) async =>
      ApiClient.decode(await widget.auth.apiGet(path));

  Future<List<dynamic>> _apiList(String path, String key) async =>
      (ApiClient.decode(await widget.auth.apiGet(path))[key] as List?) ?? [];

  /// Wraps a future in a panel-friendly loading / error / data flow.
  Widget _future<T>(Future<T> future, Widget Function(T data) build) {
    return FutureBuilder<T>(
      future: future,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.symmetric(vertical: 34), child: Center(child: CircularProgressIndicator(color: _orange, strokeWidth: 2.5)));
        }
        if (snap.hasError || !snap.hasData) {
          return _emptyText("Couldn't load — pull again later.");
        }
        return build(snap.data as T);
      },
    );
  }

  static Widget _emptyText(String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Text(t, textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 13, color: _grey)),
      );

  // "Coming soon" placeholder for features that are built but not yet live to
  // students (currently Leaderboard & Forum). Keeps the tile openable so it still
  // expands with the shared Hero-morph, just showing a friendly holding state.
  static Widget _comingSoon(IconData icon, String title, String blurb) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: _orange.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 34, color: _orange),
          ),
          const SizedBox(height: 20),
          Text(title, textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w700, color: _isDark ? Colors.white : const Color(0xFF1A1712))),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: _orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text('Coming soon', style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: _orange)),
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Text(blurb, textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 13.5, height: 1.5, color: _grey)),
          ),
        ]),
      );

  static String _fmtAt(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${months[dt.month - 1]} ${dt.day}, $h:${dt.minute.toString().padLeft(2, '0')} $ampm';
  }

  @override
  Widget build(BuildContext context) {
    _isDark = Theme.of(context).brightness == Brightness.dark;
    // One scrollable column: top bar, profile card, then the big tile matrix.
    // The matrix fills the width (large on tablets/iPad); a floating button
    // helps scroll when it runs past the screen.
    return Scaffold(
      backgroundColor: _bg,
      floatingActionButton: _scrollFab(),
      body: Stack(
        children: [
          // Soft, colourful backdrop the frosted-glass panels refract.
          const Positioned.fill(child: _GlassBackdrop()),
          SafeArea(child: _homeBody()),
        ],
      ),
    );
  }

  Widget _homeBody() => LayoutBuilder(builder: (context, c) {
        // Desktop: news pinned on the RIGHT next to the matrix.
        // iPad / phone: one scrolling column with news BELOW the matrix.
        return c.maxWidth >= 1000 ? _wideHome(c) : _narrowHome(c);
      });

  // Desktop: top bar across the top, the menu matrix on the left, and the AI
  // news pinned as a right-hand sidebar (its list scrolls internally).
  Widget _wideHome(BoxConstraints c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 8, 36, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Entrance(index: 0, child: _topBar()),
        const SizedBox(height: 14),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              // Size the board to the smaller free dimension of its box so it
              // always fits — no overflow, no scroll.
              child: LayoutBuilder(builder: (_, mc) {
                final avail = mc.maxWidth < mc.maxHeight ? mc.maxWidth : mc.maxHeight;
                final side = (avail - 6).clamp(200.0, 900.0).toDouble();
                return Center(child: _matrix(side));
              }),
            ),
            const SizedBox(width: 28),
            // Right sidebar: profile on top, notifications, then AI news.
            SizedBox(
              width: 480,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _Entrance(index: 1, child: _profileSection()),
                const SizedBox(height: 12),
                _Entrance(index: 2, child: _homeNotifications()),
                const SizedBox(height: 12),
                Expanded(child: _Entrance(index: 3, child: _AiNewsCard(auth: widget.auth, scrollable: true))),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }

  // iPad / phone: a single scrolling column — big matrix, then AI news below it
  // (shrink-wrapped so it flows with the page scroll). The floating scroll
  // button appears when this runs off-screen.
  // iPad / phone: a single NON-scrolling screen — brand bar, a compact profile,
  // then the checkerboard fills the rest so all tiles are visible at once.
  Widget _narrowHome(BoxConstraints c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
      child: Column(children: [
        _Entrance(index: 0, child: _topBar()),
        const SizedBox(height: 12),
        _Entrance(index: 1, child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: _profileSection(compact: true)))),
        const SizedBox(height: 12),
        // The matrix fills the remaining space, sized to the smaller of the free
        // width/height so the full 5×5 board is always on screen — no scrolling.
        Expanded(
          child: _Entrance(
            index: 2,
            child: Center(
              child: LayoutBuilder(builder: (_, cc) {
                // Size to the smaller free dimension, minus a small margin so a
                // sub-pixel/border rounding never tips it into an overflow.
                final avail = cc.maxWidth < cc.maxHeight ? cc.maxWidth : cc.maxHeight;
                final s = (avail - 6).clamp(120.0, 1000.0).toDouble();
                return _matrix(s);
              }),
            ),
          ),
        ),
      ]),
    );
  }

  // ---- Profile section (right sidebar on desktop, top on iPad/phone) --------

  Widget _profileSection({bool compact = false}) {
    final initials = _firstName.isNotEmpty ? _firstName[0].toUpperCase() : 'S';
    final avatar = compact ? 84.0 : 104.0; // bigger profile picture
    final hi = compact ? 20.0 : 23.0;
    return _HoverCard(
      onTap: () => _openPanel('profile'),
      padding: const EdgeInsets.all(18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ValueListenableBuilder<String>(
              valueListenable: avatarNotifier,
              builder: (ctx, av, _) => _avatarBox(av, avatar, initials),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                RichText(
                  text: TextSpan(children: [
                    TextSpan(text: 'Hi, ', style: GoogleFonts.inter(fontSize: hi, fontWeight: FontWeight.w800, color: _navy)),
                    TextSpan(text: _firstName, style: GoogleFonts.inter(fontSize: hi, fontWeight: FontWeight.w800, color: _orange)),
                  ]),
                ),
                const SizedBox(height: 3),
                Text(_roleLabel, style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w600, color: _grey)),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(color: _orange.withOpacity(0.12)),
                    child: Text('ONROL Learner', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: _orange)),
                  ),
                  _streakChip(),
                ]),
              ]),
            ),
            // Gear opens the Settings panel (not the profile) — its own tap
            // wins over the card's, so only this icon goes to Settings.
            _Pressable(
              onTap: () => _openPanel('settings'),
              child: Container(
                width: 34, height: 34, alignment: Alignment.center,
                decoration: BoxDecoration(color: _orange.withOpacity(0.10), border: Border.all(color: _orange.withOpacity(0.22))),
                child: Icon(CupertinoIcons.gear_alt_fill, size: 18, color: _orange.withOpacity(0.8)),
              ),
            ),
          ]),
    );
  }

  // Themed day-streak chip (fire + count). Tap opens the Achievements panel.
  Widget _streakChip() => GestureDetector(
        onTap: () => _openPanel('achievements'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            gradient: _orangeGrad,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(CupertinoIcons.flame_fill, color: Colors.white, size: 14),
            const SizedBox(width: 4),
            Text('$_streak day streak', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
          ]),
        ),
      );

  String get _roleLabel {
    switch (widget.auth.user?.role) {
      case 'instructor':
        return 'ONROL Instructor';
      case 'manager':
        return 'ONROL Manager';
      case 'superadmin':
        return 'ONROL Admin';
      default:
        return 'ONROL Student';
    }
  }

  // A notification BUTTON on the home (next to the profile, not inside a panel).
  // Tapping it pops up the full Notifications panel like the other features.
  Widget _homeNotifications() => _future(
        Future.wait([
          _apiList('/api/v1/me/notifications', 'notifications'),
          _apiList('/api/v1/me/announcements', 'announcements'),
        ]),
        (List d) {
          final personal = (d[0] as List);
          final unseen = personal.where((n) => (n as Map)['read'] != true).length;
          // Mirror the unread count onto the browser tab title (web only).
          setUnreadBadge(unseen);
          final all = <Map<String, dynamic>>[];
          for (final n in personal) {
            final m = n as Map<String, dynamic>;
            final b = m['body']?.toString() ?? '';
            all.add({'text': [m['title'] ?? '', if (b.isNotEmpty) '— $b'].join(' '), 'at': m['at']});
          }
          for (final a in (d[1] as List)) {
            final m = a as Map<String, dynamic>;
            final b = m['body']?.toString() ?? '';
            final course = m['course']?.toString() ?? '';
            all.add({'text': [if (course.isNotEmpty) '[$course]', m['title'] ?? '', if (b.isNotEmpty) '— $b'].join(' '), 'at': m['at']});
          }
          all.sort((a, b) => (b['at']?.toString() ?? '').compareTo(a['at']?.toString() ?? ''));
          final preview = all.isEmpty ? 'No notifications yet' : (all.first['text'] as String);
          return _HoverCard(
            onTap: () => _openPanel('notifications'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(children: [
                Stack(clipBehavior: Clip.none, children: [
                  Container(width: 40, height: 40, alignment: Alignment.center, decoration: BoxDecoration(color: _orange.withOpacity(0.12), shape: BoxShape.circle), child: Icon(CupertinoIcons.bell_fill, size: 19, color: _orange)),
                  if (unseen > 0)
                    Positioned(right: -3, top: -3, child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      constraints: const BoxConstraints(minWidth: 17),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: const Color(0xFFE5484D), borderRadius: BorderRadius.zero, border: Border.all(color: _bg, width: 1.5)),
                      child: Text(unseen > 99 ? '99+' : '$unseen', style: GoogleFonts.inter(fontSize: 9.5, fontWeight: FontWeight.w800, color: Colors.white)),
                    )),
                ]),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('Notifications', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w800, color: _navy)),
                    if (unseen > 0) ...[
                      const SizedBox(width: 6),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1), decoration: BoxDecoration(color: _orange.withOpacity(0.14), borderRadius: BorderRadius.zero), child: Text('$unseen new', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w800, color: _orange))),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 12, color: _grey)),
                ])),
                const SizedBox(width: 6),
                Icon(CupertinoIcons.chevron_forward, size: 17, color: _grey),
              ]),
          );
        },
      );

  // ---- Top bar -------------------------------------------------------------

  Widget _topBar() {
    // Just the brand — the corner avatar is gone; the profile card opens Profile.
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
      child: Row(children: [
        Text('ONROL', style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w800, color: _orange, letterSpacing: 1)),
      ]),
    );
  }

  // ---- Checkerboard — flush square tiles, sized to fit `side` --------------

  Widget _matrix(double side) {
    const gap = 0.0;
    // 5 cells + 4 gaps span `side`.
    final cell = (side - gap * 4) / 5;
    var idx = 0;
    final rows = <Widget>[];
    for (var r = 0; r < 5; r++) {
      final cells = <Widget>[];
      for (var c = 0; c < 5; c++) {
        // Start blank at (0,0); tiles on the alternating (r+c)-odd cells.
        final filled = (r + c).isOdd && idx < _tiles.length;
        final tile = filled ? _tiles[idx++] : null;
        cells.add(Padding(
          padding: EdgeInsets.only(right: c < 4 ? gap : 0, bottom: r < 4 ? gap : 0),
          child: tile == null
              ? SizedBox(width: cell, height: cell)
              : Hero(
                  tag: 'panel-${tile.panel}',
                  createRectTween: _smoothHeroRect,
                  child: _GridCell(tile: tile, size: cell, onTap: (c) => _openPanel(tile.panel, origin: c)),
                ),
        ));
      }
      rows.add(Row(mainAxisSize: MainAxisSize.min, children: cells));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  // ---- Profile card (right sidebar, top) -----------------------------------

  // A square (rounded) profile picture. [avatar] is '' / 'p:N' (preset) or a
  // 'data:' URI (uploaded photo). Shows a camera badge when [editable].
  void _toast(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  // Pick a photo and save it as a small square JPEG data URI. The picker first
  // downscales (browser canvas on web / native on mobile); we then crop to a
  // 256px square with the `image` package, falling back to the picker's bytes
  // if Dart can't decode them (e.g. an unusual format).
  Future<void> _uploadAvatar(BuildContext dialogCtx) async {
    try {
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (x == null) return; // user cancelled
      final raw = await x.readAsBytes();
      if (raw.isEmpty) {
        _toast("That image was empty — try another.");
        return;
      }
      Uint8List out;
      String mime;
      final decoded = img.decodeImage(raw);
      if (decoded != null) {
        out = img.encodeJpg(img.copyResizeCropSquare(decoded, size: 256), quality: 82);
        mime = 'image/jpeg';
      } else {
        out = raw; // already downscaled by the picker
        mime = x.mimeType ?? 'image/png';
      }
      if (out.lengthInBytes > 900000) {
        _toast('Image too large — try a smaller one.');
        return;
      }
      await _setAvatar('data:$mime;base64,${base64Encode(out)}');
      if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
      _toast('Profile picture updated');
    } catch (e) {
      _toast('Upload failed: $e');
    }
  }

  // Default-picture picker + "upload your own".
  void _pickAvatar() {
    final initials = _firstName.isNotEmpty ? _firstName[0].toUpperCase() : 'S';
    showDialog(
      context: context,
      barrierColor: const Color(0x55000000),
      builder: (ctx) => Center(
        child: Material(
          type: MaterialType.transparency,
          child: _glass(
            radius: 24,
            padding: const EdgeInsets.all(22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Choose a picture', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700, color: _navy)),
                const SizedBox(height: 3),
                Text('Pick a default or upload your own', style: GoogleFonts.inter(fontSize: 13, color: _grey)),
                const SizedBox(height: 18),
                ValueListenableBuilder<String>(
                  valueListenable: avatarNotifier,
                  builder: (c, sel, _) => Wrap(
                    spacing: 12, runSpacing: 12,
                    children: [
                      for (var i = 0; i < _avatars.length; i++)
                        GestureDetector(
                          onTap: () {
                            _setAvatar('p:$i');
                            Navigator.of(ctx).pop();
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.zero,
                              border: Border.all(color: sel == 'p:$i' || (sel.isEmpty && i == 0) ? _orange : Colors.transparent, width: 3),
                            ),
                            child: _avatarBox('p:$i', 58, initials),
                          ),
                        ),
                      // Upload-your-own tile.
                      GestureDetector(
                        onTap: () => _uploadAvatar(ctx),
                        child: Container(
                          width: 64, height: 64, alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.zero,
                            color: _orange.withOpacity(0.10),
                            border: Border.all(color: _orange.withOpacity(0.5), width: 1.5),
                          ),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(CupertinoIcons.cloud_upload_fill, size: 22, color: _orange),
                            const SizedBox(height: 2),
                            Text('Upload', style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w700, color: _orange)),
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: _Pressable(
                    onTap: () => Navigator.of(ctx).pop(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Text('Close', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _orange)),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // ---- Modal panels --------------------------------------------------------

  void _openPanel(String key, {Offset? origin}) {
    // Every tile — including the forum — opens through the same shared-element
    // route, so it expands out of its tile (iOS-style) exactly like the others.
    final d = _panel(key);
    final closed = _showPanel(d.$1, d.$2, d.$3, d.$4, heroTag: 'panel-$key', compact: key == 'logout');
    if (key == 'notifications') {
      // Reading marks them read server-side; refresh the home badge once the
      // panel closes so the unread count actually clears (don't leave it stale).
      closed.whenComplete(() async {
        try { await widget.auth.apiPost('/api/v1/me/notifications/read', {}); } catch (_) {}
        setUnreadBadge(0);
        if (mounted) setState(() {});
      });
    }
  }

  // Course content viewer — modules & lessons from /me/courses/:id/content.
  // A wide course thumbnail/banner shown atop the content view.
  Widget _courseBanner(String url) {
    Widget? pic;
    if (url.startsWith('data:')) {
      try {
        pic = Image.memory(base64Decode(url.substring(url.indexOf(',') + 1)), height: 220, width: double.infinity, fit: BoxFit.cover);
      } catch (_) {}
    } else if (url.startsWith('http')) {
      pic = Image.network(url, height: 220, width: double.infinity, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox());
    }
    if (pic == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ClipRRect(borderRadius: BorderRadius.zero, child: pic),
    );
  }

  void _openContent(String courseId, String title, {String? imageUrl}) {
    _showPanel(CupertinoIcons.book_fill, title, 'Course content', [
      if (imageUrl != null && imageUrl.isNotEmpty) _courseBanner(imageUrl),
      _future(Future.wait([_apiMap('/api/v1/me/courses/$courseId/content'), _apiList('/api/v1/me/assessments', 'assessments')]), (List d) {
        final m = d[0] as Map<String, dynamic>;
        final modules = (m['modules'] as List?) ?? [];
        final assessments = (d[1] as List).where((a) => (a as Map<String, dynamic>)['course']?.toString() == title).toList();
        if (modules.isEmpty && assessments.isEmpty) return _emptyText('No content in this course yet.');
        return StatefulBuilder(builder: (ctx, setS) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Course-wide quiz grade (percentage) once the student has taken a quiz.
            if (m['course_grade'] != null)
              Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                decoration: BoxDecoration(color: _green.withOpacity(0.08), border: Border.all(color: _green.withOpacity(0.35))),
                child: Row(children: [
                  Icon(CupertinoIcons.chart_bar_alt_fill, size: 16, color: _green),
                  const SizedBox(width: 8),
                  Text('Course grade', style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w700, color: _navy)),
                  const Spacer(),
                  Text('${(m['course_grade'] as num).round()}%', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: _green)),
                ]),
              ),
            // The course's day-wise assignments & quizzes sit inside the first
            // module's day boxes, alongside that day's lessons.
            for (var i = 0; i < modules.length; i++)
              _moduleBox(modules[i] as Map<String, dynamic>, () => setS(() {}), assessments: i == 0 ? assessments : const []),
            // No modules but there are assessments → show them as day boxes.
            if (modules.isEmpty && assessments.isNotEmpty)
              ..._lessonsByDay(const [], () => setS(() {}), assessments: assessments),
          ]);
        });
      }),
    ]);
  }

  // A single assessment row (tap to open the quiz / assignment).
  Widget _assessmentTile(Map<String, dynamic> m) {
    final isQuiz = m['type'] == 'quiz';
    final submitted = m['submitted'] == true;
    final status = m['status']?.toString() ?? '';
    final score = m['score'];
    String badge;
    Color? badgeBg, badgeFg;
    if (submitted) {
      if (status == 'graded' && score != null) {
        badge = '${(score as num).round()}%';
        badgeBg = _greenBg;
        badgeFg = _green;
      } else if (status == 'submitted') {
        badge = 'Grading…';
        badgeBg = _orange.withOpacity(0.12);
        badgeFg = _orange;
      } else {
        badge = 'Submitted';
        badgeBg = _greenBg;
        badgeFg = _green;
      }
    } else {
      badge = isQuiz ? 'Start' : 'Pending';
    }
    return GestureDetector(
      onTap: () => _openAssessment(m),
      child: _row(
        isQuiz ? CupertinoIcons.question_square_fill : CupertinoIcons.doc_text_fill,
        m['title']?.toString() ?? 'Assessment',
        isQuiz ? 'Quiz · ${m['questions'] ?? 0} questions · 1 pt each' : 'Assignment',
        badge,
        badgeBg: badgeBg,
        badgeFg: badgeFg,
      ),
    );
  }

  // Small green "N%" grade pill — a student's quiz score for a module or course.
  Widget _gradePill(int pct) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: _green.withOpacity(0.12), border: Border.all(color: _green.withOpacity(0.4))),
        child: Text('$pct%', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800, color: _green)),
      );

  // One module as a bordered box: a tinted title bar, its day folders, a
  // comments link, and any nested sub-modules (indented boxes below).
  Widget _moduleBox(Map<String, dynamic> md, VoidCallback rebuild, {bool isSub = false, List assessments = const []}) {
    final lessons = (md['lessons'] as List?) ?? [];
    final subs = (md['submodules'] as List?) ?? [];
    final title = md['title']?.toString() ?? 'Module';
    return Container(
      margin: EdgeInsets.only(top: isSub ? 8 : 12, left: isSub ? 10 : 0),
      decoration: BoxDecoration(color: _surface, border: Border.all(color: _cardBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _orange.withOpacity(isSub ? 0.05 : 0.08),
            border: Border(bottom: BorderSide(color: _cardBorder)),
          ),
          child: Row(children: [
            if (isSub) Padding(padding: const EdgeInsets.only(right: 6), child: Icon(Icons.subdirectory_arrow_right, size: 15, color: _orange)),
            Expanded(child: Text(title, style: GoogleFonts.inter(fontSize: isSub ? 13.5 : 15, fontWeight: FontWeight.w700, color: _orange))),
            if (md['grade'] != null) _gradePill((md['grade'] as num).round()),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (lessons.isEmpty && subs.isEmpty && assessments.isEmpty)
              _emptyText('No lessons.')
            else if (lessons.isNotEmpty || assessments.isNotEmpty)
              ..._lessonsByDay(lessons, rebuild, assessments: assessments, dayLabels: (md['day_labels'] as Map?)?.cast<String, dynamic>() ?? const {}),
            // "Ask your mentor" lives in its own home tile now (not per module).
            // Nested sub-modules.
            for (final s in subs) _moduleBox(s as Map<String, dynamic>, rebuild, isSub: true),
          ]),
        ),
      ]),
    );
  }

  // Group a module's lessons by day (Day 1, Day 2, … then "Unscheduled"). Any
  // [assessments] are grouped by the same day and shown inside that day's box.
  List<Widget> _lessonsByDay(List lessons, VoidCallback rebuild, {List assessments = const [], Map<String, dynamic> dayLabels = const {}}) {
    final groups = <int?, List<Map<String, dynamic>>>{};
    for (final l in lessons) {
      final ll = l as Map<String, dynamic>;
      groups.putIfAbsent((ll['day_number'] as num?)?.toInt(), () => []).add(ll);
    }
    final aGroups = <int?, List<Map<String, dynamic>>>{};
    for (final a in assessments) {
      final am = a as Map<String, dynamic>;
      aGroups.putIfAbsent((am['day_number'] as num?)?.toInt(), () => []).add(am);
    }
    final keys = <int?>{...groups.keys, ...aGroups.keys}.toList()
      ..sort((a, b) {
        if (a == null) return 1;
        if (b == null) return -1;
        return a.compareTo(b);
      });
    // Full lesson order (Day 1, 2, … then Unscheduled) for the reader's prev/next.
    final ordered = <Map<String, dynamic>>[for (final k in keys) ...(groups[k] ?? const [])];
    final out = <Widget>[];
    for (final k in keys) {
      final ls = groups[k] ?? const [];
      final asmts = aGroups[k] ?? const [];
      final children = <Widget>[
        ...ls.map((ll) => _lessonRow(ll, rebuild, siblings: ordered)),
        ...asmts.map((m) => _assessmentTile(m)),
      ];
      final custom = k == null ? '' : (dayLabels[k.toString()]?.toString() ?? '');
      out.add(_DayFolder(
        label: k == null ? 'Unscheduled' : (custom.isNotEmpty ? custom : 'Day $k'),
        count: children.length,
        children: children,
      ));
    }
    return out;
  }

  // Private mentor channel: the student sees only their own messages + the
  // mentor's replies (never other students'). Everything they post is queued for
  // the mentor/admin to answer. [basePath] scopes the thread — a module
  // (/api/v1/modules/:id) or a course's General thread (/api/v1/courses/:id).
  void _openComments(String basePath, String title) {
    final text = TextEditingController();
    bool doubt = false;
    _showPanel(CupertinoIcons.chat_bubble_2_fill, title, 'Ask your mentor — private', [
      StatefulBuilder(builder: (ctx, setS) {
        Future<void> post() async {
          if (text.text.trim().isEmpty) return;
          try {
            await widget.auth.apiPost('$basePath/comments', {'body': text.text.trim(), 'is_doubt': doubt});
            text.clear();
            setS(() {});
          } catch (_) {}
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Privacy note so students know this isn't a public thread.
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: _orange.withOpacity(0.08), border: Border.all(color: _orange.withOpacity(0.25))),
            child: Row(children: [
              Icon(CupertinoIcons.lock_fill, size: 13, color: _orange),
              const SizedBox(width: 8),
              Expanded(child: Text('Private — only your mentor sees this. Your questions are queued for them to answer.', style: GoogleFonts.inter(fontSize: 11.5, height: 1.35, color: _grey))),
            ]),
          ),
          _future(_apiList('$basePath/comments', 'comments'), (List items) {
            if (items.isEmpty) return _emptyText('No messages yet. Ask your mentor a question — only they can see it.');
            return Column(children: items.map((e) {
              final m = e as Map<String, dynamic>;
              final staff = m['staff'] == true;
              final isDoubt = m['is_doubt'] == true;
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(gradient: _cardGradient, borderRadius: BorderRadius.zero, border: Border.all(color: _cardBorder)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(m['author']?.toString() ?? 'Someone', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: _navy)),
                    const SizedBox(width: 6),
                    if (staff) Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: _orange.withOpacity(0.14), borderRadius: BorderRadius.zero), child: Text('Mentor', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: _orange))),
                    if (isDoubt) Container(margin: const EdgeInsets.only(left: 6), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: const Color(0xFF2D7DF6).withOpacity(0.14), borderRadius: BorderRadius.zero), child: Text('Doubt', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: const Color(0xFF2D7DF6)))),
                  ]),
                  const SizedBox(height: 4),
                  Text(m['body']?.toString() ?? '', style: GoogleFonts.inter(fontSize: 14, color: _navy, height: 1.4)),
                ]),
              );
            }).toList());
          }),
          const SizedBox(height: 12),
          CupertinoTextField(controller: text, placeholder: 'Ask your mentor a question…', minLines: 1, maxLines: 4, padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(gradient: _cardGradient, borderRadius: BorderRadius.zero, border: Border.all(color: _cardBorder))),
          const SizedBox(height: 8),
          Row(children: [
            _Pressable(onTap: () => setS(() => doubt = !doubt), child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(doubt ? CupertinoIcons.checkmark_square_fill : CupertinoIcons.square, size: 18, color: doubt ? _orange : _grey),
              const SizedBox(width: 6),
              Text('Mark as doubt', style: GoogleFonts.inter(fontSize: 13, color: _navy)),
            ])),
            const Spacer(),
            _Pressable(onTap: post, child: Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10), decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero),
                child: Text('Post', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)))),
          ]),
        ]);
      }),
    ]);
  }

  // Animated confirmation overlay (checkmark / paper-plane scales + fades in,
  // then auto-dismisses).
  void _showRequestSent(String title, String sub, IconData icon) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'sent',
      barrierColor: const Color(0x66000000),
      transitionDuration: const Duration(milliseconds: 300),
      transitionBuilder: (ctx, anim, sec, child) {
        final c = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        return FadeTransition(opacity: c, child: ScaleTransition(scale: Tween<double>(begin: 0.85, end: 1.0).animate(c), child: child));
      },
      pageBuilder: (ctx, anim, sec) {
        _isDark = Theme.of(ctx).brightness == Brightness.dark;
        // Auto-dismiss shortly after it appears.
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
        });
        return Center(
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              width: 300,
              child: _glass(
              radius: 22,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 480),
                  curve: Curves.easeOutBack,
                  builder: (_, v, __) => Transform.scale(
                    scale: v,
                    child: Container(
                      width: 72, height: 72, alignment: Alignment.center,
                      decoration: BoxDecoration(color: _orange.withOpacity(0.12), shape: BoxShape.circle),
                      child: Icon(icon, size: 40, color: _orange),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(title, textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700, color: _navy)),
                const SizedBox(height: 6),
                Text(sub, textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 13, color: _grey, height: 1.4)),
              ]),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _lessonRow(Map<String, dynamic> l, VoidCallback onChanged, {List<Map<String, dynamic>>? siblings}) {
    final type = l['type']?.toString() ?? 'text';
    final done = l['completed'] == true;
    final icon = switch (type) {
      'video' => CupertinoIcons.play_rectangle_fill,
      'link' => CupertinoIcons.link,
      'scorm' || 'xapi' => CupertinoIcons.cube_box_fill,
      _ => CupertinoIcons.doc_text_fill,
    };
    return _HoverRow(
      onTap: () => _openLesson(l, siblings: siblings),
      child: Row(children: [
        Icon(icon, size: 20, color: _orange),
        const SizedBox(width: 12),
        Expanded(child: Text(l['title']?.toString() ?? 'Lesson', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: _navy))),
        if (type == 'file') ...[
          Icon(l['downloadable'] == true ? CupertinoIcons.cloud_download_fill : CupertinoIcons.eye_fill, size: 15, color: _grey),
          const SizedBox(width: 8),
        ],
        // Tappable completion toggle (works for every lesson type). Tap the
        // circle to mark done; until then Resume keeps bringing you back here.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: done
              ? null
              : () async {
                  try {
                    await widget.auth.apiPost('/api/v1/me/lessons/${l['id']}/complete', {});
                    l['completed'] = true;
                    onChanged();
                  } catch (_) {}
                },
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(done ? CupertinoIcons.checkmark_alt_circle_fill : CupertinoIcons.circle, size: 22, color: done ? _green : _grey),
          ),
        ),
      ]),
    );
  }

  // Dispatches a live-class tap: a simulated-live session (a recorded video
  // served as live) opens our in-app live room; an external (Zoho/Meet/Jitsi)
  // session keeps the existing WebView/new-tab behavior.
  void _openLive(Map<String, dynamic> session) {
    if ((session['kind']?.toString() ?? 'external') == 'simulated') {
      final id = session['id']?.toString() ?? '';
      if (id.isEmpty || !mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LiveSessionScreen(
          auth: widget.auth,
          sessionId: id,
          watermark: widget.auth.user?.email ?? 'student',
          title: session['title']?.toString() ?? 'Live Class',
        ),
      ));
      return;
    }
    _openUrl(session['join_url']?.toString() ?? '');
  }

  // Joins a live class (Zoho / Meet / Jitsi link). On mobile we load it inside
  // the app via LiveScreen — a WebView that follows Zoho's register→session
  // redirect and keeps the student in-app under their forensic watermark — so
  // tapping Join always opens the session instead of silently bouncing out to
  // Safari. On web (no in-app WebView) we open it in a new tab.
  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || url.isEmpty) return;
    if (!kIsWeb) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LiveScreen(url: url, watermark: widget.auth.user?.email ?? 'student'),
      ));
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
    } catch (_) {}
  }

  Future<void> _openLesson(Map<String, dynamic> l, {List<Map<String, dynamic>>? siblings}) async {
    final id = l['id'].toString();
    final url = l['url']?.toString() ?? '';
    final type = l['type']?.toString() ?? 'text';
    if ((type == 'link' || type == 'file') && url.startsWith('http')) {
      // Open the link / document (PDF, Word, …) — browser renders or downloads it.
      try {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
      } catch (_) {}
    } else if (url.isNotEmpty) {
      // Text OR video material: open the full-page reader positioned here. The
      // video plays INLINE in the material view (not a separate bare player).
      // Previous/Next page through ALL the materials in this module.
      final items = (siblings != null && siblings.isNotEmpty) ? siblings : <Map<String, dynamic>>[l];
      var idx = items.indexWhere((x) => x['id'].toString() == id);
      if (idx < 0) idx = 0;
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => _TextMaterialScreen(
            auth: widget.auth,
            items: items,
            index: idx,
            onOpen: (m) => _openLesson(m),
          ),
        ));
      }
      return; // the reader stamps progress per material it shows
    }
    // Stamp last-access, and auto-mark link/document materials complete on open
    // (text auto-completes in the reader; videos complete when watched).
    widget.auth.apiPost('/api/v1/me/lessons/$id/progress', {'position': 0}).ignore();
    if (type == 'link' || type == 'file') {
      l['completed'] = true;
      widget.auth.apiPost('/api/v1/me/lessons/$id/complete', {}).ignore();
    }
  }

  // Opens a quiz (loads questions, collects answers) or an assignment (a
  // free-text submission + link), and submits them.
  Future<void> _openAssessment(Map<String, dynamic> a) async {
    final id = a['id'].toString();
    final isAssignment = (a['type']?.toString() ?? 'quiz') == 'assignment';
    final answers = <String, String>{};
    _showPanel(isAssignment ? CupertinoIcons.doc_text_fill : CupertinoIcons.question_square_fill,
        a['title']?.toString() ?? (isAssignment ? 'Assignment' : 'Quiz'),
        a['course']?.toString() ?? (isAssignment ? 'Assignment' : 'Quiz'), [
      _future(_apiMap('/api/v1/me/assessments/$id'), (m) {
        if (isAssignment) return _assignmentView(id, m);
        final qs = (m['questions'] as List?) ?? [];
        if (qs.isEmpty) return _emptyText('This quiz has no questions yet.');
        // Once submitted, the quiz is locked: show the submitted answers, no edits.
        final submission = (m['submission'] as Map?)?.cast<String, dynamic>() ?? {};
        final submittedAnswers = (submission['answers'] as Map?)?.cast<String, dynamic>() ?? {};
        final locked = submittedAnswers.isNotEmpty;
        if (locked && answers.isEmpty) {
          submittedAnswers.forEach((k, v) => answers[k] = v?.toString() ?? '');
        }
        final subScore = submission['score'];
        final subStatus = submission['status']?.toString() ?? '';
        return StatefulBuilder(builder: (ctx, setS) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (locked) ...[
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: _green.withOpacity(0.10), border: Border.all(color: _green)),
                child: Row(children: [
                  Icon(CupertinoIcons.checkmark_seal_fill, size: 17, color: _green),
                  const SizedBox(width: 6),
                  Expanded(child: Text(
                    subStatus == 'graded' && subScore != null
                        ? 'Submitted · scored ${(subScore as num).round()}%. Your answers are below.'
                        : 'Submitted ✓ — your answers are locked and shown below.',
                    style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: _navy))),
                ]),
              ),
            ],
            ...qs.asMap().entries.map((e) {
              final q = e.value as Map<String, dynamic>;
              final qid = q['id'].toString();
              final type = q['type']?.toString() ?? 'short';
              final opts = type == 'truefalse'
                  ? const ['true', 'false']
                  : ((q['options'] as List?)?.map((o) => o.toString()).toList() ?? const <String>[]);
              return Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${e.key + 1}. ${q['prompt'] ?? ''}',
                      style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600, color: _navy)),
                  const SizedBox(height: 8),
                  if (type == 'upload')
                    _Pressable(
                      onTap: locked ? null : () async {
                        try {
                          final res = await FilePicker.platform.pickFiles(withData: true);
                          if (res == null || res.files.isEmpty) return;
                          final pf = res.files.first;
                          final bytes = pf.bytes;
                          if (bytes == null) return;
                          await widget.auth.apiUpload('/api/v1/me/assessments/$id/files', bytes: bytes, filename: pf.name);
                          setS(() => answers[qid] = pf.name);
                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Uploaded ${pf.name}')));
                        } catch (_) {
                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Upload failed — try again.')));
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                        decoration: BoxDecoration(color: _orange.withOpacity(0.08), border: Border.all(color: _orange)),
                        child: Row(children: [
                          Icon((answers[qid] ?? '').isNotEmpty ? CupertinoIcons.checkmark_alt_circle_fill : CupertinoIcons.cloud_upload_fill, size: 17, color: _orange),
                          const SizedBox(width: 8),
                          Expanded(child: Text((answers[qid] ?? '').isNotEmpty ? 'Uploaded: ${answers[qid]}' : 'Upload a file', maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w700, color: _orange))),
                        ]),
                      ),
                    )
                  else if (type == 'multi')
                    // Multiple response. After submit: green = correct, red = wrong pick.
                    Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: opts.map((o) {
                      List<String> sel;
                      try {
                        sel = (jsonDecode(answers[qid] ?? '[]') as List).map((e) => e.toString()).toList();
                      } catch (_) {
                        sel = <String>[];
                      }
                      List<String> correctList = const [];
                      if (locked) {
                        try {
                          correctList = (jsonDecode(q['correct']?.toString() ?? '[]') as List).map((e) => e.toString()).toList();
                        } catch (_) {}
                      }
                      final on = sel.contains(o);
                      final isCorrect = locked && correctList.contains(o);
                      final wrongPick = locked && on && !isCorrect;
                      final bd = isCorrect ? _green : wrongPick ? _danger : (on ? _orange : _line);
                      final bg = isCorrect ? _green.withOpacity(0.14) : wrongPick ? _danger.withOpacity(0.12) : (on ? _orange.withOpacity(0.12) : _bg);
                      return _Pressable(
                        onTap: locked ? null : () => setS(() {
                          final cur = [...sel];
                          on ? cur.remove(o) : cur.add(o);
                          answers[qid] = jsonEncode(cur);
                        }),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.zero, border: Border.all(color: bd)),
                          child: Row(children: [
                            Icon(on ? CupertinoIcons.checkmark_square_fill : CupertinoIcons.square, size: 18, color: on ? (wrongPick ? _danger : _orange) : _grey),
                            const SizedBox(width: 10),
                            Expanded(child: Text(o, style: GoogleFonts.inter(fontSize: 14, color: _navy))),
                            if (isCorrect) const Icon(CupertinoIcons.checkmark_alt, size: 15, color: _green),
                            if (wrongPick) const Icon(CupertinoIcons.xmark, size: 14, color: _danger),
                          ]),
                        ),
                      );
                    }).toList())
                  else if (opts.isNotEmpty)
                    ...opts.map((o) {
                      final correct = q['correct']?.toString() ?? '';
                      final picked = answers[qid] == o;
                      final isCorrect = locked && o == correct;
                      final wrongPick = locked && picked && !isCorrect;
                      final bd = isCorrect ? _green : wrongPick ? _danger : (picked ? _orange : _line);
                      final bg = isCorrect ? _green.withOpacity(0.14) : wrongPick ? _danger.withOpacity(0.12) : (picked ? _orange.withOpacity(0.12) : _bg);
                      final icColor = isCorrect ? _green : wrongPick ? _danger : (picked ? _orange : _grey);
                      final ic = isCorrect
                          ? CupertinoIcons.checkmark_circle_fill
                          : wrongPick
                              ? CupertinoIcons.xmark_circle_fill
                              : (picked ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle);
                      return _Pressable(
                        onTap: locked ? null : () => setS(() => answers[qid] = o),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.zero, border: Border.all(color: bd)),
                          child: Row(children: [
                            Icon(ic, size: 18, color: icColor),
                            const SizedBox(width: 10),
                            Expanded(child: Text(o, style: GoogleFonts.inter(fontSize: 14, color: _navy))),
                          ]),
                        ),
                      );
                    })
                  else if (locked)
                    Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: _surface, border: Border.all(color: _cardBorder)),
                        child: Text((answers[qid] ?? '').trim().isEmpty ? '— no answer —' : answers[qid]!,
                            style: GoogleFonts.inter(fontSize: 14, color: (answers[qid] ?? '').trim().isEmpty ? _grey : _navy)),
                      ),
                      if (type != 'essay' && type != 'upload' && (q['correct']?.toString() ?? '').isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Row(children: [
                          Icon(CupertinoIcons.checkmark_seal_fill, size: 14, color: _green),
                          const SizedBox(width: 6),
                          Expanded(child: Text('Correct answer: ${(q['correct'] as String).replaceAll('|', ' / ')}', style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w600, color: _green))),
                        ]),
                      ],
                    ])
                  else
                    CupertinoTextField(
                      placeholder: 'Your answer',
                      onChanged: (v) => answers[qid] = v,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(gradient: _cardGradient, borderRadius: BorderRadius.zero, border: Border.all(color: _cardBorder)),
                    ),
                ]),
              );
            }),
            if (!locked) const SizedBox(height: 8),
            if (!locked) _Pressable(
              onTap: () async {
                try {
                  final res = await widget.auth.apiPost('/api/v1/me/assessments/$id/submit', {'answers': answers});
                  if (!mounted) return;
                  Navigator.of(ctx).pop();
                  // Show the auto-graded result (and XP earned) right away.
                  String msg = 'Submitted ✓';
                  try {
                    final r = jsonDecode(res.body) as Map<String, dynamic>;
                    if (r['needs_manual_grading'] == true) {
                      msg = 'Submitted ✓ — written answers will be graded soon.';
                    } else {
                      final pct = (r['percent'] as num?)?.toInt() ?? 0;
                      final correct = (r['correct'] as num?)?.toInt() ?? 0;
                      final total = (r['total'] as num?)?.toInt() ?? 0;
                      msg = 'Scored $pct%  ·  $correct/$total correct  ·  +$pct XP 🎉';
                    }
                  } catch (_) {}
                  // Refresh the dashboard so the new quiz XP shows immediately.
                  setState(() {});
                  _playSubmitAnimation('Submitted!');
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                } catch (_) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't submit — try again.")));
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero),
                child: Text('Submit', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            ),
          ]);
        });
      }),
    ]);
  }

  // Assignment: a free-text response + an optional attachment link. Shows the
  // student's current submission and, once graded, their score + feedback.
  Widget _assignmentView(String id, Map<String, dynamic> m) {
    final sub = (m['submission'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final maxScore = (m['max_score'] as num?)?.round() ?? 100;
    final autoAward = m['auto_award'] == true;
    final due = m['due_at']?.toString() ?? '';
    final body = TextEditingController(text: sub['body']?.toString() ?? '');
    final link = TextEditingController(text: sub['link']?.toString() ?? '');
    final files = ((sub['files'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    String fileSize(int b) => b < 1024 ? '$b B' : b < 1048576 ? '${(b / 1024).round()} KB' : '${(b / 1048576).toStringAsFixed(1)} MB';
    InputDecoration deco(String hint) => InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.inter(color: _grey, fontSize: 14),
          isDense: true,
          contentPadding: const EdgeInsets.all(12),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: _cardBorder)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: const BorderSide(color: _orange)),
        );
    return StatefulBuilder(builder: (ctx, setS) {
      final status = sub['status']?.toString() ?? '';
      final graded = status == 'graded';
      final submitted = status.isNotEmpty;
      final score = (sub['score'] as num?);
      final feedback = sub['feedback']?.toString() ?? '';

      Future<void> upload() async {
        try {
          final res = await FilePicker.platform.pickFiles(withData: true);
          if (res == null || res.files.isEmpty) return;
          final pf = res.files.first;
          final bytes = pf.bytes;
          if (bytes == null) return;
          final r = await widget.auth.apiUpload('/api/v1/me/assessments/$id/files', bytes: bytes, filename: pf.name);
          final mm = jsonDecode(r.body) as Map<String, dynamic>;
          files.add({'id': mm['id'], 'filename': mm['filename'] ?? pf.name, 'size': mm['size'] ?? bytes.length});
          sub['status'] = autoAward ? 'graded' : 'submitted';
          if (autoAward) sub['score'] = maxScore;
          setS(() {});
          if (mounted) {
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(autoAward ? 'Uploaded ✓ — full marks awarded' : 'Uploaded ✓')));
          }
        } catch (_) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Upload failed — try again.')));
        }
      }

      Future<void> removeFile(Map<String, dynamic> f) async {
        try {
          await widget.auth.apiDelete('/api/v1/me/submission-files/${f['id']}');
          files.removeWhere((x) => x['id'] == f['id']);
          setS(() {});
        } catch (_) {}
      }

      Future<void> download(Map<String, dynamic> f) async {
        try {
          final r = await widget.auth.apiGet('/api/v1/me/submission-files/${f['id']}');
          saveFileBytes(f['filename']?.toString() ?? 'file', '', r.bodyBytes);
        } catch (_) {}
      }

      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (due.isNotEmpty) ...[
          Row(children: [
            Icon(CupertinoIcons.calendar, size: 15, color: _grey),
            const SizedBox(width: 6),
            Text('Due ${_fmtAt(due)}', style: GoogleFonts.inter(fontSize: 12.5, color: _grey)),
          ]),
          const SizedBox(height: 12),
        ],
        if (autoAward && !graded) ...[
          Row(children: [
            Icon(CupertinoIcons.bolt_fill, size: 14, color: _orange),
            const SizedBox(width: 6),
            Expanded(child: Text('Full marks are awarded automatically on submission.', style: GoogleFonts.inter(fontSize: 12.5, color: _grey))),
          ]),
          const SizedBox(height: 12),
        ],
        if (graded) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: _green.withOpacity(0.10), border: Border.all(color: _green)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(CupertinoIcons.checkmark_seal_fill, size: 17, color: _green),
                const SizedBox(width: 6),
                Text('Graded  ·  ${score?.round() ?? 0}%', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _navy)),
              ]),
              if (feedback.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(feedback, style: GoogleFonts.inter(fontSize: 13, color: _navy, height: 1.4)),
              ],
            ]),
          ),
          const SizedBox(height: 14),
        ] else if (submitted) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: _orange.withOpacity(0.10), border: Border.all(color: _orange)),
            child: Row(children: [
              Icon(CupertinoIcons.clock_fill, size: 16, color: _orange),
              const SizedBox(width: 6),
              Expanded(child: Text('Submitted ✓ — awaiting grading. You can update it below.', style: GoogleFonts.inter(fontSize: 13, color: _navy))),
            ]),
          ),
          const SizedBox(height: 14),
        ],
        Text('Your response', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: _navy)),
        const SizedBox(height: 6),
        TextField(controller: body, minLines: 6, maxLines: 14, style: GoogleFonts.inter(fontSize: 14, color: _navy, height: 1.4), decoration: deco('Write your answer…')),
        const SizedBox(height: 12),
        Text('Attachment link (optional)', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: _navy)),
        const SizedBox(height: 6),
        TextField(controller: link, style: GoogleFonts.inter(fontSize: 14, color: _navy), decoration: deco('Paste a link — Google Drive, GitHub, …')),
        const SizedBox(height: 14),
        // ---- File uploads --------------------------------------------------
        Text('Upload files', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: _navy)),
        const SizedBox(height: 6),
        for (final f in files)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: _surface, border: Border.all(color: _cardBorder)),
            child: Row(children: [
              Icon(CupertinoIcons.doc_fill, size: 16, color: _orange),
              const SizedBox(width: 8),
              Expanded(child: Text(f['filename']?.toString() ?? 'file', maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 13, color: _navy))),
              Text(fileSize((f['size'] as num?)?.toInt() ?? 0), style: GoogleFonts.inter(fontSize: 11.5, color: _grey)),
              const SizedBox(width: 8),
              _Pressable(onTap: () => download(f), child: Icon(CupertinoIcons.cloud_download, size: 17, color: _grey)),
              const SizedBox(width: 10),
              _Pressable(onTap: () => removeFile(f), child: const Icon(CupertinoIcons.xmark, size: 16, color: Color(0xFFBDBDBD))),
            ]),
          ),
        _Pressable(
          onTap: upload,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: _orange.withOpacity(0.08), border: Border.all(color: _orange)),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(CupertinoIcons.cloud_upload_fill, size: 16, color: _orange),
              const SizedBox(width: 6),
              Text('Upload a file', style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w700, color: _orange)),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        _Pressable(
          onTap: () async {
            if (body.text.trim().isEmpty && link.text.trim().isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Write a response or paste a link (or just upload a file above).')));
              return;
            }
            try {
              await widget.auth.apiPost('/api/v1/me/assessments/$id/submit', {'body': body.text.trim(), 'link': link.text.trim()});
              sub['status'] = autoAward ? 'graded' : 'submitted';
              if (autoAward) sub['score'] = maxScore;
              sub['body'] = body.text.trim();
              sub['link'] = link.text.trim();
              setS(() {});
              if (mounted) {
                setState(() {});
                _playSubmitAnimation(autoAward ? 'Full marks! 🎉' : 'Submitted!');
              }
            } catch (_) {
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't submit — try again.")));
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero),
            child: Text(submitted ? 'Resubmit' : 'Submit', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
        ),
      ]);
    });
  }

  // A brief success-checkmark pop played when a submit succeeds.
  void _playSubmitAnimation([String label = 'Submitted!']) {
    if (!mounted) return;
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'submitted',
      barrierColor: Colors.black.withOpacity(0.22),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => _SubmitSuccess(label: label),
      transitionBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    );
  }

  Future<void> _showPanel(IconData icon, String title, String sub, List<Widget> body, {String? heroTag, bool compact = false}) {
    // iOS-style shared-element expansion: push a transparent route so the
    // dashboard stays visible (blurred) behind, and let a Hero morph the tapped
    // tile into the card. See [_PanelRoute] / [_HeroPanelModal]. Returns the
    // route's future so callers can act once the panel is dismissed.
    return Navigator.of(context).push(_PanelRoute(
      child: _HeroPanelModal(icon: icon, title: title, sub: sub, body: body, heroTag: heroTag, compact: compact),
    ));
  }

  // Returns (icon, title, subtitle, body widgets) for a panel key.
  (IconData, String, String, List<Widget>) _panel(String key) {
    switch (key) {
      case 'dashboard':
        return (CupertinoIcons.square_grid_2x2_fill, 'Dashboard', 'Your learning overview', [
          _future(
            Future.wait([
              _apiMap('/api/v1/me/transcript'),
              _apiList('/api/v1/me/courses', 'my_courses'),
            ]),
            (List d) {
              final t = d[0] as Map<String, dynamic>;
              final courses = d[1] as List;
              final totalL = courses.fold<int>(0, (s, c) => s + (((c as Map)['lessons_total'] ?? 0) as num).toInt());
              final doneL = courses.fold<int>(0, (s, c) => s + (((c as Map)['lessons_done'] ?? 0) as num).toInt());
              final overall = totalL > 0 ? doneL / totalL : 0.0;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // Personal greeting with the user's avatar.
                _Entrance(
                  index: 0,
                  child: Row(children: [
                    ValueListenableBuilder<String>(
                      valueListenable: avatarNotifier,
                      builder: (c, av, _) => _avatarBox(av, 46, _firstName.isNotEmpty ? _firstName[0].toUpperCase() : 'S'),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Hi, $_firstName 👋', style: GoogleFonts.inter(fontSize: 19, fontWeight: FontWeight.w700, color: _navy)),
                        const SizedBox(height: 2),
                        Text("Here's your learning snapshot", style: GoogleFonts.inter(fontSize: 13, color: _grey)),
                      ]),
                    ),
                  ]),
                ),
                const SizedBox(height: 14),
                // Continue where you left off (replaces the old Resume tile).
                if (courses.isNotEmpty)
                  _Entrance(index: 1, child: _orangeButton('▶  Continue learning', () => _openPanel('resume'))),
                const SizedBox(height: 18),
                // Overall-progress hero with an animated ring.
                if (courses.isNotEmpty) ...[
                  _Entrance(
                    index: 1,
                    child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: _cardGradient,
                      borderRadius: BorderRadius.zero,
                      border: Border.all(color: _cardBorder),
                    ),
                    child: Row(children: [
                      SizedBox(
                        width: 66, height: 66,
                        child: Stack(alignment: Alignment.center, children: [
                          TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: overall),
                            duration: const Duration(milliseconds: 900),
                            curve: Curves.easeOutCubic,
                            builder: (_, v, __) => SizedBox(
                              width: 66, height: 66,
                              child: CircularProgressIndicator(value: v, strokeWidth: 7, backgroundColor: _isDark ? const Color(0xFF2C2F37) : const Color(0xFFF0EBE8), valueColor: const AlwaysStoppedAnimation(_orange)),
                            ),
                          ),
                          Text('${(overall * 100).round()}%', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w800, color: _orange)),
                        ]),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Overall progress', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: _navy)),
                          const SizedBox(height: 3),
                          Text(doneL > 0 ? '$doneL of $totalL lessons complete — keep going!' : 'Start a lesson to build your streak', style: GoogleFonts.inter(fontSize: 12.5, color: _grey, height: 1.4)),
                        ]),
                      ),
                    ]),
                  )),
                  const SizedBox(height: 16),
                ],
                _Entrance(
                  index: 2,
                  child: Row(children: [
                    Expanded(child: _statCard('${t['enrolled'] ?? 0}', 'Enrolled', icon: CupertinoIcons.book_fill, onTap: () => _openPanel('courses'))),
                    const SizedBox(width: 14),
                    Expanded(child: _statCard('${t['completed'] ?? 0}', 'Completed', icon: CupertinoIcons.checkmark_seal_fill, onTap: () => _openPanel('courses'))),
                  ]),
                ),
                const SizedBox(height: 14),
                _Entrance(
                  index: 3,
                  child: Row(children: [
                    Expanded(child: _statCard('${_xpFromCourses(courses) + ((t['quiz_xp'] ?? 0) as num).toInt()}', 'XP earned', icon: CupertinoIcons.bolt_fill, onTap: () => _openPanel('achievements'))),
                    const SizedBox(width: 14),
                    Expanded(child: _statCard('${t['certificates'] ?? 0}', 'Certificates', icon: CupertinoIcons.rosette, onTap: () => _openPanel('certificates'))),
                  ]),
                ),
                // (Notifications intentionally omitted here — they live in the
                // sidebar card and the dedicated Notifications tile.)
              ]);
            },
          ),
        ]);
      case 'notifications':
        return (CupertinoIcons.bell_fill, 'Notifications', 'Updates & announcements', [
          _future(
            Future.wait([
              _apiList('/api/v1/me/notifications', 'notifications'),
              _apiList('/api/v1/me/announcements', 'announcements'),
            ]),
            (List d) {
              // Mark personal notifications read (best-effort) once viewed, and
              // clear the browser-tab unread badge right away (web only).
              widget.auth.apiPost('/api/v1/me/notifications/read', {}).ignore();
              setUnreadBadge(0);
              final entries = <Map<String, dynamic>>[];
              for (final n in (d[0] as List)) {
                final m = n as Map<String, dynamic>;
                entries.add({'title': (m['title'] ?? '').toString(), 'body': m['body']?.toString() ?? '', 'at': m['at'], 'read': m['read'] == true});
              }
              for (final a in (d[1] as List)) {
                final m = a as Map<String, dynamic>;
                final course = m['course']?.toString() ?? '';
                final titleLine = [if (course.isNotEmpty) '[$course]', m['title'] ?? ''].join(' ');
                entries.add({'title': titleLine, 'body': m['body']?.toString() ?? '', 'at': m['at'], 'read': true});
              }
              entries.sort((a, b) => (b['at']?.toString() ?? '').compareTo(a['at']?.toString() ?? ''));
              if (entries.isEmpty) return _emptyText('No notifications yet.');
              return Column(children: entries.map((e) => _notif(e['title'] as String, _fmtAt(e['at']?.toString()), read: e['read'] == true, body: (e['body'] as String?)?.isNotEmpty == true ? e['body'] as String : null)).toList());
            },
          ),
        ]);
      case 'resume':
        return (CupertinoIcons.play_circle_fill, 'Resume Learning', 'Continue any course in one tap', [
          _future(_apiMap('/api/v1/me/resume'), (m) {
            final list = (m['courses'] as List?) ?? [];
            if (list.isEmpty) return _emptyText("You're all caught up — nothing to resume.");
            return Column(children: [
              for (var i = 0; i < list.length; i++)
                _ResumeCard(
                  index: i,
                  data: list[i] as Map<String, dynamic>,
                  onContinue: (lesson) {
                    Navigator.of(context).maybePop();
                    _openLesson(lesson);
                  },
                ),
            ]);
          }),
        ]);
      case 'courses':
        return (CupertinoIcons.book_fill, 'My Courses', 'Tap a course to open its content', [
          _future(_apiList('/api/v1/me/courses', 'my_courses'), (List courses) {
            if (courses.isEmpty) return _emptyText('No courses yet.');
            return Column(children: [
              for (var i = 0; i < courses.length; i++)
                Builder(builder: (_) {
                  final m = courses[i] as Map<String, dynamic>;
                  final done = ((m['lessons_done'] ?? 0) as num).toInt();
                  final total = ((m['lessons_total'] ?? 0) as num).toInt();
                  return _Entrance(
                    index: i,
                    child: _CourseCard(
                      index: i,
                      title: m['title']?.toString() ?? 'Course',
                      done: done,
                      total: total,
                      percent: ((m['percent'] ?? 0) as num).toInt(),
                      grade: (m['grade'] as num?)?.toInt(),
                      imageUrl: m['image_url']?.toString(),
                      onOpen: () => _openContent(m['id'].toString(), m['title']?.toString() ?? 'Course', imageUrl: m['image_url']?.toString()),
                    ),
                  );
                }),
            ]);
          }),
        ]);
      case 'profile':
        // A clean, standalone profile panel (separate from notifications):
        // photo + identity with a change-photo action. Detail-collection fields
        // were intentionally dropped as redundant.
        return (CupertinoIcons.person_fill, 'Profile', _name, [
          Center(
            child: Column(children: [
              const SizedBox(height: 6),
              GestureDetector(
                onTap: _pickAvatar,
                child: ValueListenableBuilder<String>(
                  valueListenable: avatarNotifier,
                  builder: (c, av, _) => _avatarBox(av, 100, _firstName.isNotEmpty ? _firstName[0].toUpperCase() : 'S', editable: true),
                ),
              ),
              const SizedBox(height: 14),
              Text(_name, style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w800, color: _navy)),
              const SizedBox(height: 3),
              Text(_roleLabel, style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w600, color: _orange)),
              if ((widget.auth.user?.email ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(widget.auth.user!.email, style: GoogleFonts.inter(fontSize: 12.5, color: _grey)),
              ],
              // Login ID — the short code the student can sign in with.
              _future(_apiMap('/api/v1/me/profile'), (Map m) {
                final lid = (m['login_id'] ?? '').toString();
                if (lid.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: _orange.withOpacity(0.10), border: Border.all(color: _orange.withOpacity(0.28))),
                    child: Text('Login ID: $lid', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: _orange)),
                  ),
                );
              }),
              const SizedBox(height: 16),
              // Streak + notifications, consolidated into the profile panel.
              Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero, ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(CupertinoIcons.flame_fill, color: Colors.white, size: 15),
                    const SizedBox(width: 5),
                    Text('$_streak day streak', style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white)),
                  ]),
                ),
              ]),
              const SizedBox(height: 18),
              _myDevicesSection(),
              const SizedBox(height: 4),
              // Settings + change-photo surfaced up front (not buried).
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _Pressable(
                  onTap: () => _openPanel('settings'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(CupertinoIcons.gear_alt_fill, size: 16, color: Colors.white),
                      const SizedBox(width: 8),
                      Text('Settings', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
                    ]),
                  ),
                ),
                const SizedBox(width: 10),
                _Pressable(
                  onTap: _pickAvatar,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    decoration: BoxDecoration(color: _orange.withOpacity(0.10), borderRadius: BorderRadius.zero, border: Border.all(color: _orange.withOpacity(0.35))),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(CupertinoIcons.camera_fill, size: 16, color: _orange),
                      const SizedBox(width: 8),
                      Text('Photo', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _orange)),
                    ]),
                  ),
                ),
              ]),
            ]),
          ),
        ]);
      case 'settings':
        return (CupertinoIcons.gear_alt_fill, 'Settings', 'Customize your experience', [
          _SettingsView(auth: widget.auth, onLogout: _logout),
        ]);
      case 'leaderboard':
        return (CupertinoIcons.list_number, 'Leaderboard', 'Ranked by XP — overall & per course', [
          _comingSoon(CupertinoIcons.list_number, 'Leaderboard', 'Climb the ranks and see how you stack up against your cohort by XP. We’re putting the finishing touches on it — check back soon.'),
        ]);
      case 'schedule':
        return (CupertinoIcons.calendar, 'Calendar', 'Classes, deadlines & activities', [
          _future(_apiList('/api/v1/me/calendar', 'calendar'), (List items) {
            if (items.isEmpty) return _emptyText('Nothing scheduled yet.');
            return _CalendarView(items: items, onOpenSession: _openLive);
          }),
        ]);
      case 'mentor':
        return (CupertinoIcons.chat_bubble_2_fill, 'Ask your mentor', 'Private questions & doubts — only your mentor sees them', [
          _MentorHelpView(auth: widget.auth, onAsk: (basePath, title) => _openComments(basePath, title)),
        ]);
      case 'messages':
        return (CupertinoIcons.chat_bubble_2_fill, 'Messages', 'Your inbox', [
          _future(_apiList('/api/v1/me/messages', 'inbox'), (List inbox) {
            if (inbox.isEmpty) return _emptyText('No messages.');
            return Column(children: inbox.map((e) {
              final m = e as Map<String, dynamic>;
              final from = m['from']?.toString() ?? '';
              return _notif(from.isEmpty ? (m['body']?.toString() ?? '') : '$from: ${m['body'] ?? ''}', _fmtAt(m['at']?.toString()), read: m['read'] == true);
            }).toList());
          }),
        ]);
      case 'assignments':
        return (CupertinoIcons.doc_text_fill, 'Assignments', 'Quizzes & assignments by day', [
          _future(_apiList('/api/v1/me/assessments', 'assessments'), (List items) {
            if (items.isEmpty) return _emptyText('Nothing assigned yet.');
            final courses = (<String>{for (final a in items) (a as Map)['course']?.toString() ?? ''}..remove('')).toList()..sort();
            String courseFilter = '';
            return StatefulBuilder(builder: (ctx, setS) {
              // Course-filter the items, then group by day (day-less → "Unscheduled").
              final shown = courseFilter.isEmpty ? items : items.where((a) => (a as Map<String, dynamic>)['course']?.toString() == courseFilter).toList();
              final groups = <int?, List<Map<String, dynamic>>>{};
              for (final a in shown) {
                final m = a as Map<String, dynamic>;
                final d = (m['day_number'] as num?)?.toInt();
                groups.putIfAbsent(d, () => []).add(m);
              }
              final keys = groups.keys.toList()
                ..sort((x, y) {
                  if (x == null) return 1;
                  if (y == null) return -1;
                  return x.compareTo(y);
                });
              Widget courseChip(String label, bool sel, VoidCallback onTap) => _Pressable(
                    onTap: onTap,
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(color: sel ? _orange : _surface, border: Border.all(color: sel ? _orange : _cardBorder)),
                      child: Text(label, style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w700, color: sel ? Colors.white : _navy)),
                    ),
                  );
              final children = <Widget>[];
              if (courses.length > 1) {
                children.add(Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      courseChip('All courses', courseFilter.isEmpty, () => setS(() => courseFilter = '')),
                      for (final c in courses) courseChip(c, courseFilter == c, () => setS(() => courseFilter = c)),
                    ]),
                  ),
                ));
              }
            for (final k in keys) {
              children.add(Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 4),
                child: Text(k == null ? 'Unscheduled' : 'Day $k',
                    style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: _orange)),
              ));
              for (final m in groups[k]!) {
                final isQuiz = m['type'] == 'quiz';
                final submitted = m['submitted'] == true;
                final course = m['course']?.toString() ?? '';
                final status = m['status']?.toString() ?? '';
                final score = m['score'];
                // Badge: graded → "80%" (green), awaiting human grading →
                // "Grading…" (amber), submitted-but-unknown → "Submitted",
                // otherwise the call-to-action.
                String badge;
                Color? badgeBg, badgeFg;
                if (submitted) {
                  if (status == 'graded' && score != null) {
                    badge = '${(score as num).round()}%';
                    badgeBg = _greenBg;
                    badgeFg = _green;
                  } else if (status == 'submitted') {
                    badge = 'Grading…';
                    badgeBg = _orange.withOpacity(0.12);
                    badgeFg = _orange;
                  } else {
                    badge = 'Submitted';
                    badgeBg = _greenBg;
                    badgeFg = _green;
                  }
                } else {
                  badge = isQuiz ? 'Start' : 'Pending';
                }
                children.add(GestureDetector(
                  // Open quiz (retakable, best score kept) or the assignment
                  // submission view — both by day.
                  onTap: () => _openAssessment(m),
                  child: _row(
                    isQuiz ? CupertinoIcons.question_square_fill : CupertinoIcons.doc_text_fill,
                    m['title']?.toString() ?? 'Assessment',
                    '$course · ${isQuiz ? 'Quiz · ${m['questions'] ?? 0} questions' : 'Assignment'}',
                    badge,
                    badgeBg: badgeBg,
                    badgeFg: badgeFg,
                  ),
                ));
              }
            }
              return Column(children: children);
            });
          }),
        ]);
      case 'resources':
        return (CupertinoIcons.bookmark_fill, 'Resources', 'Study materials', [
          _row(CupertinoIcons.doc_fill, 'HTML Cheat Sheet', 'PDF · 2.3 MB', 'Download'),
          _row(CupertinoIcons.play_rectangle_fill, 'CSS Flexbox Tutorial', 'Video · 45 min', 'Watch'),
          _row(CupertinoIcons.book_fill, 'Figma Handbook', 'PDF · 5.1 MB', 'Download'),
        ]);
      case 'study':
        return (CupertinoIcons.doc_richtext, 'Study Hub', 'Guides, cheat sheets, flashcards & more', [
          _StudyHub(auth: widget.auth),
        ]);
      case 'certificates':
        return (CupertinoIcons.rosette, 'Certificates', 'Your achievements', [
          _future(_apiList('/api/v1/me/certificates', 'certificates'), (List certs) {
            if (certs.isEmpty) return _emptyText('No certificates yet — complete a course to earn one.');
            return Column(children: [
              for (var i = 0; i < certs.length; i++)
                _CertCard(index: i, data: certs[i] as Map<String, dynamic>),
            ]);
          }),
        ]);
      case 'live':
        return (CupertinoIcons.videocam_fill, 'Live Classes', 'Your schedule & join links', [
          _future(_apiList('/api/v1/me/live', 'live'), (List live) {
            if (live.isEmpty) return _emptyText('No live classes scheduled.');
            return _LiveAgenda(items: live, onJoin: _openLive);
          }),
        ]);
      case 'help':
        return (CupertinoIcons.question_circle_fill, 'Help Center', "We're here for you", [
          _help('How do I download my certificate?', 'Go to Certificates → View → Download PDF'),
          _help('How do I join a live class?', 'Go to Schedule → tap Join 5 min before'),
          _help('How to track progress?', 'Dashboard shows completion % per course'),
          const SizedBox(height: 16),
          _orangeButton('Chat with Support', () => Navigator.of(context).pop()),
        ]);
      case 'payments':
        return (CupertinoIcons.creditcard_fill, 'Payments', 'Billing & subscriptions', [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_orange.withOpacity(0.14), _orange.withOpacity(0.05)]), borderRadius: BorderRadius.zero),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Current Plan', style: GoogleFonts.inter(fontSize: 13, color: _grey)),
              const SizedBox(height: 4),
              Text('ONROL Pro', style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w700, color: _orange)),
              Text('Renews July 10, 2026', style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFFAAAAAA))),
            ]),
          ),
          const SizedBox(height: 14),
          _row(CupertinoIcons.doc_text, 'June 2026 — ₹999', 'Pro Plan · Paid', 'Paid', badgeBg: _greenBg, badgeFg: _green),
          _row(CupertinoIcons.doc_text, 'May 2026 — ₹999', 'Pro Plan · Paid', 'Paid', badgeBg: _greenBg, badgeFg: _green),
        ]);
      case 'notes':
        return (CupertinoIcons.square_pencil_fill, 'My Notes', 'Your private study notes', [
          _NotesView(auth: widget.auth),
        ]);
      case 'quizzes':
        return (CupertinoIcons.lightbulb_fill, 'Quizzes', 'Test your knowledge', [
          _row(CupertinoIcons.bolt_fill, 'JavaScript Basics Quiz', '30 Qs · 45 min · Due today 4:30 PM', 'Start', badgeBg: const Color(0xFFFFF0EC), badgeFg: const Color(0xFFE05A2A)),
          _row(CupertinoIcons.paintbrush_fill, 'UI Principles Quiz', '20 Qs · 30 min', 'Start'),
          _row(CupertinoIcons.chart_bar_fill, 'Data Types Quiz', '15 Qs · 20 min · Completed', '90%', badgeBg: _greenBg, badgeFg: _green),
        ]);
      case 'calendar':
        return (CupertinoIcons.calendar, 'Calendar', 'Classes, deadlines & activities', [
          _future(_apiList('/api/v1/me/calendar', 'calendar'), (List items) {
            if (items.isEmpty) return _emptyText('Nothing scheduled yet.');
            return _CalendarView(items: items, onOpenSession: _openLive);
          }),
        ]);
      case 'announcements':
        return (CupertinoIcons.speaker_2_fill, 'Announcements', 'Latest from ONROL', [
          _notif('New course launched: Advanced React Patterns — enroll now!', '1 day ago'),
          _notif('Scheduled maintenance Sunday 2 AM–4 AM IST.', '2 days ago', read: true),
          _notif('Win prizes in the June coding challenge.', '3 days ago', read: true),
        ]);
      case 'search':
        return (CupertinoIcons.search, 'Search', 'Find courses & lessons', [
          _field('SEARCH', ''),
          const SizedBox(height: 8),
          Text('Popular searches', style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFFAAAAAA), fontWeight: FontWeight.w600, letterSpacing: 0.5)),
          const SizedBox(height: 6),
          _row(CupertinoIcons.device_laptop, 'JavaScript Basics', 'Course · 4.8 rating', 'Open'),
          _row(CupertinoIcons.paintbrush_fill, 'Figma Crash Course', 'Course · 4.9 rating', 'Open'),
          _row(CupertinoIcons.cube_box_fill, 'Intro to Machine Learning', 'Course · 4.7 rating', 'Open'),
        ]);
      case 'bookmarks':
        return (CupertinoIcons.star_fill, 'Bookmarks', 'Saved for later', [
          _row(CupertinoIcons.device_laptop, 'Responsive Design Guide', 'Web Dev · Article', 'Read'),
          _row(CupertinoIcons.play_rectangle_fill, 'CSS Grid Masterclass', 'Video · 32 min', 'Watch'),
          _row(CupertinoIcons.doc_fill, 'Figma Shortcuts PDF', 'UI/UX · PDF', 'Open'),
        ]);
      case 'achievements':
        return (CupertinoIcons.flame_fill, 'Achievements', "Badges you've earned", [
          _row(CupertinoIcons.flame_fill, '7-Day Streak', 'Kept learning all week', 'Earned', badgeBg: _greenBg, badgeFg: _green),
          _row(CupertinoIcons.scope, 'First Course Done', 'Completed HTML Fundamentals', 'Earned', badgeBg: _greenBg, badgeFg: _green),
          _row(CupertinoIcons.star_fill, 'Top 3 This Week', 'Leaderboard rank #3', 'Earned', badgeBg: _greenBg, badgeFg: _green),
          _row(CupertinoIcons.rocket_fill, 'Quick Learner', '5 lessons in a single day', 'Locked'),
        ]);
      case 'explore':
        return (CupertinoIcons.compass_fill, 'Explore Courses', 'Browse all courses, batch-wise', [
          _ExploreList(
            auth: widget.auth,
            onEnrolled: (title, self) => _showRequestSent(
              self ? 'Enrolled!' : 'Request sent',
              self ? "You're now enrolled in $title." : "Your request for $title was sent — you'll be notified when it's approved.",
              self ? CupertinoIcons.checkmark_alt_circle_fill : CupertinoIcons.paperplane_fill,
            ),
          ),
        ]);
      case 'logout':
      default:
        return (CupertinoIcons.square_arrow_right, 'Log Out', 'See you soon!', [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Soft gradient badge with a gentle pop-in.
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.7, end: 1),
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutBack,
                builder: (_, v, child) => Transform.scale(scale: v, child: child),
                child: Container(
                  width: 88, height: 88, alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: _orangeGrad,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(CupertinoIcons.hand_raised_fill, size: 38, color: Colors.white),
                ),
              ),
              const SizedBox(height: 20),
              Text('Heading off, $_firstName?', textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700, color: _navy)),
              const SizedBox(height: 6),
              Text('Your progress is saved — jump back in anytime.',
                  textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 13.5, color: _grey, height: 1.5)),
              const SizedBox(height: 26),
              Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                // Compact "Stay" pill — subtle tinted.
                _Pressable(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
                    decoration: BoxDecoration(
                      color: _orange.withOpacity(0.10),
                      borderRadius: BorderRadius.zero,
                      border: Border.all(color: _orange.withOpacity(0.28)),
                    ),
                    child: Text('Stay', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _orange)),
                  ),
                ),
                const SizedBox(width: 12),
                // Compact "Log Out" gradient pill with icon + glow.
                _Pressable(
                  onTap: () { Navigator.of(context).pop(); _logout(); },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      gradient: _orangeGrad,
                      borderRadius: BorderRadius.zero,
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(CupertinoIcons.square_arrow_right, size: 16, color: Colors.white),
                      const SizedBox(width: 7),
                      Text('Log Out', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
                    ]),
                  ),
                ),
              ]),
            ]),
          ),
        ]);
    }
  }
}

// ---- Reusable panel components ---------------------------------------------

Widget _statCard(String value, String label, {IconData? icon, VoidCallback? onTap}) =>
    _StatCard(value: value, label: label, icon: icon, onTap: onTap);

Widget _notif(String text, String time, {bool read = false, String? body}) => _StudentHomeNotif(text: text, time: time, read: read, body: body);

Widget _row(IconData icon, String name, String meta, String badge, {Color? badgeBg, Color? badgeFg}) =>
    _PanelRow(icon: icon, name: name, meta: meta, badge: badge, badgeBg: badgeBg, badgeFg: badgeFg);

/// A panel list row that highlights + nudges on hover.
class _PanelRow extends StatefulWidget {
  const _PanelRow({required this.icon, required this.name, required this.meta, required this.badge, this.badgeBg, this.badgeFg});
  final IconData icon;
  final String name;
  final String meta;
  final String badge;
  final Color? badgeBg;
  final Color? badgeFg;

  @override
  State<_PanelRow> createState() => _PanelRowState();
}

class _PanelRowState extends State<_PanelRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
        // Every row is its own box: a solid surface + hairline border at rest,
        // with a light orange wash + stronger border on hover.
        decoration: BoxDecoration(
          color: _hover ? Color.alphaBlend(_orange.withOpacity(0.06), _surface) : _surface,
          borderRadius: BorderRadius.zero,
          border: Border.all(color: _hover ? _orange.withOpacity(0.55) : _cardBorder, width: 1),
        ),
        child: Row(children: [
          Container(width: 44, height: 44, alignment: Alignment.center, decoration: BoxDecoration(color: _orange.withOpacity(0.12), borderRadius: BorderRadius.zero), child: Icon(widget.icon, size: 20, color: _orange)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.name, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: _navy)),
            Text(widget.meta, style: GoogleFonts.inter(fontSize: 12, color: _grey)),
          ])),
          const SizedBox(width: 8),
          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: widget.badgeBg ?? _peach, borderRadius: BorderRadius.zero),
              child: Text(widget.badge, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: widget.badgeFg ?? _orange))),
        ]),
      ),
    );
  }
}

/// An issued certificate: rosette seal, course, issued date + serial, and
/// View / Download actions that open the printable certificate page.
class _CertCard extends StatefulWidget {
  const _CertCard({required this.index, required this.data});
  final int index;
  final Map<String, dynamic> data;

  @override
  State<_CertCard> createState() => _CertCardState();
}

class _CertCardState extends State<_CertCard> {
  bool _hover = false;

  String? get _serial => widget.data['serial']?.toString();

  Future<void> _open({bool download = false}) async {
    final serial = _serial;
    if (serial == null || serial.isEmpty) return;
    final url = '${appcfg.Config.apiBase}/api/v1/certificates/$serial${download ? '?download=1' : ''}';
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.data;
    final course = m['course']?.toString() ?? 'Certificate';
    final serial = _serial ?? '';
    final issued = _StudentHomeState._fmtAt(m['issued_at']?.toString());

    return _Entrance(
      index: widget.index,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(14),
          transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
          decoration: BoxDecoration(
            gradient: _cardGradient,
            borderRadius: BorderRadius.zero,
            border: Border.all(color: _hover ? _orange.withOpacity(0.40) : _cardBorder, width: 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Rosette seal.
              Container(
                width: 52, height: 52, alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: _orangeGrad,
                  borderRadius: BorderRadius.zero,
                ),
                child: const Icon(CupertinoIcons.rosette, size: 26, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(course, maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: _navy)),
                  const SizedBox(height: 3),
                  Text('Issued $issued', style: GoogleFonts.inter(fontSize: 12, color: _grey)),
                  if (serial.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('ID $serial', style: GoogleFonts.inter(fontSize: 11, color: _grey, fontWeight: FontWeight.w500)),
                    ),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _certBtn('View', CupertinoIcons.eye_fill, false, () => _open())),
              const SizedBox(width: 10),
              Expanded(child: _certBtn('Download', CupertinoIcons.cloud_download_fill, true, () => _open(download: true))),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _certBtn(String label, IconData icon, bool filled, VoidCallback onTap) => _Pressable(
        onTap: onTap,
        child: Container(
          height: 42, alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: filled ? _orangeGrad : null,
            color: filled ? null : _orange.withOpacity(0.10),
            borderRadius: BorderRadius.zero,
            border: filled ? null : Border.all(color: _orange.withOpacity(0.30)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: filled ? Colors.white : _orange),
            const SizedBox(width: 7),
            Text(label, style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w600, color: filled ? Colors.white : _orange)),
          ]),
        ),
      );
}

/// Explore / catalog list. Enrolling updates the row in place to "Enrolled"
/// (or "Requested") so the action is immediately reflected — no full reload.
class _ExploreList extends StatefulWidget {
  const _ExploreList({required this.auth, required this.onEnrolled});
  final AuthService auth;
  final void Function(String title, bool self) onEnrolled;

  @override
  State<_ExploreList> createState() => _ExploreListState();
}

class _ExploreListState extends State<_ExploreList> {
  late Future<List<dynamic>> _future = _load();
  final Set<String> _enrolled = {};
  final Set<String> _requested = {};
  final Set<String> _busy = {};

  Future<List<dynamic>> _load() async {
    final m = ApiClient.decode(await widget.auth.apiGet('/api/v1/catalog'));
    return (m['catalog'] as List?) ?? [];
  }

  Future<void> _enroll(String id, String title, bool self) async {
    if (_busy.contains(id) || _enrolled.contains(id) || _requested.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await widget.auth.apiPost('/api/v1/me/courses/$id/enroll', {});
      if (!mounted) return;
      setState(() {
        _busy.remove(id);
        (self ? _enrolled : _requested).add(id);
      });
      widget.onEnrolled(title, self);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy.remove(id));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not enroll'), behavior: SnackBarBehavior.floating));
    }
  }

  Future<void> _openLink(String url) async {
    var u = url.trim();
    if (u.isEmpty) return;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    final uri = Uri.tryParse(u);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<dynamic>>(
      future: _future,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.symmetric(vertical: 34), child: Center(child: CircularProgressIndicator(color: _orange, strokeWidth: 2.5)));
        }
        final cat = snap.hasData ? snap.data! : const [];
        if (cat.isEmpty) {
          return Padding(padding: const EdgeInsets.symmetric(vertical: 22), child: Text('No courses available right now.', textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 13, color: _grey)));
        }
        // Group batch-wise (by category — the catalog's grouping field).
        final groups = <String, List>{};
        for (final c in cat) {
          final k = ((c as Map)['category']?.toString() ?? '').trim();
          groups.putIfAbsent(k.isEmpty ? 'General' : k, () => []).add(c);
        }
        var idx = 0;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: groups.entries.expand<Widget>((e) => [
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Text(e.key, style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: _orange)),
          ),
          ...e.value.map((c) => _courseRow(c as Map<String, dynamic>, idx++)),
        ]).toList());
      },
    );
  }

  // A visual course tile: cover image, title, description and an enroll button.
  Widget _courseRow(Map<String, dynamic> m, int index) {
    final id = m['id'].toString();
    final self = m['enroll_type'] == 'self';
    final title = m['title']?.toString() ?? 'Course';
    final desc = m['description']?.toString() ?? '';
    final img = m['image_url']?.toString() ?? '';
    final link = m['explore_link']?.toString().trim() ?? '';
    final enrolled = _enrolled.contains(id);
    final requested = _requested.contains(id);
    final busy = _busy.contains(id);
    final done = enrolled || requested;
    final badge = busy ? '…' : (enrolled ? 'Enrolled' : (requested ? 'Requested' : (self ? 'Enroll' : 'Request')));

    return _Entrance(
      index: index,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(color: _surface, border: Border.all(color: _cardBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _tileCover(img),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: _navy)),
              if (desc.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(desc, maxLines: 3, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 13, color: _grey, height: 1.45)),
              ],
              const SizedBox(height: 12),
              Row(children: [
                _Pressable(
                  onTap: done || busy ? null : () => _enroll(id, title, self),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(gradient: done ? null : _orangeGrad, color: done ? _greenBg : null),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(done ? CupertinoIcons.checkmark_alt : (self ? CupertinoIcons.arrow_right_circle_fill : CupertinoIcons.paperplane_fill), size: 15, color: done ? _green : Colors.white),
                      const SizedBox(width: 6),
                      Text(badge, style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w700, color: done ? _green : Colors.white)),
                    ]),
                  ),
                ),
                if (link.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  _Pressable(
                    onTap: () => _openLink(link),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(color: _surface, border: Border.all(color: _cardBorder)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(CupertinoIcons.info_circle, size: 15, color: _orange),
                        const SizedBox(width: 6),
                        Text('Know more', style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w700, color: _orange)),
                      ]),
                    ),
                  ),
                ],
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _tileCover(String url) {
    final fallback = Container(
      decoration: const BoxDecoration(gradient: _orangeGrad),
      child: Center(child: Icon(CupertinoIcons.book_fill, color: Colors.white.withOpacity(0.9), size: 40)),
    );
    Widget inner;
    if (url.trim().isEmpty) {
      inner = fallback;
    } else if (url.startsWith('data:')) {
      try {
        inner = Image.memory(base64Decode(url.substring(url.indexOf(',') + 1)), width: double.infinity, fit: BoxFit.cover);
      } catch (_) {
        inner = fallback;
      }
    } else {
      inner = Image.network(url, width: double.infinity, fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback);
    }
    // Fixed 4:3 cover — the image fills and crops to fit.
    return AspectRatio(aspectRatio: 4 / 3, child: SizedBox.expand(child: inner));
  }
}

/// Study Hub: pick a course, then open a resource (guides, cheat sheets, mind
/// maps, flashcards, formula sheets) filled with content. Interactive +
/// animated; example content for "AI Architect" and "AI Generalist".
class _StudyResource {
  const _StudyResource(this.id, this.icon, this.title, this.sub, this.colors, [this.unit = 'items']);
  final String id;
  final IconData icon;
  final String title;
  final String sub;
  final List<Color> colors;
  final String unit; // for the count chip, e.g. "6 guides"
}

class _StudyHub extends StatefulWidget {
  const _StudyHub({required this.auth});
  final AuthService auth;
  @override
  State<_StudyHub> createState() => _StudyHubState();
}

class _StudyHubState extends State<_StudyHub> {
  int _course = 0; // index into _courses
  String? _open; // resource id, null = grid

  List<Map<String, dynamic>> _courses = [];   // the student's enrolled courses
  List<Map<String, dynamic>> _materials = []; // material for the selected course
  bool _loadingCourses = true;
  bool _loadingMat = false;

  @override
  void initState() {
    super.initState();
    _loadCourses();
  }

  Future<void> _loadCourses() async {
    try {
      final list = ((ApiClient.decode(await widget.auth.apiGet('/api/v1/me/courses'))['my_courses'] as List?) ?? [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      if (!mounted) return;
      setState(() { _courses = list; _loadingCourses = false; });
      if (_courses.isNotEmpty) _loadMaterials();
    } catch (_) {
      if (mounted) setState(() => _loadingCourses = false);
    }
  }

  Future<void> _loadMaterials() async {
    if (_courses.isEmpty) return;
    final id = _courses[_course]['id'].toString();
    setState(() => _loadingMat = true);
    try {
      final list = ((ApiClient.decode(await widget.auth.apiGet('/api/v1/me/courses/$id/study'))['materials'] as List?) ?? [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      if (!mounted) return;
      setState(() { _materials = list; _loadingMat = false; });
    } catch (_) {
      if (mounted) setState(() { _materials = []; _loadingMat = false; });
    }
  }

  void _selectCourse(int i) {
    if (i == _course) return;
    setState(() { _course = i; _materials = []; });
    _loadMaterials();
  }

  // Material of one kind for the selected course, plus a small list coercion.
  List<Map<String, dynamic>> _mat(String kind) =>
      _materials.where((m) => m['kind'] == kind).toList();
  List<String> _strs(dynamic items) =>
      (items as List?)?.map((e) => e.toString()).toList() ?? const [];

  static const _resources = <_StudyResource>[
    _StudyResource('focus', CupertinoIcons.timer_fill, 'Focus Timer', 'Pomodoro sessions — study, break, repeat', [Color(0xFFFF4F2B), Color(0xFFFF8A5B)]),
    _StudyResource('guides', CupertinoIcons.book_fill, 'Study Guides', 'Structured notes for every topic', [Color(0xFFFF6B35), Color(0xFFFF9166)], 'guides'),
    _StudyResource('cheats', CupertinoIcons.doc_text_fill, 'Cheat Sheets', 'Quick-reference summaries', [Color(0xFFE0A12A), Color(0xFFF6C453)], 'sheets'),
    _StudyResource('mindmap', CupertinoIcons.rectangle_3_offgrid_fill, 'Mind Maps', 'See how concepts connect', [Color(0xFF18A999), Color(0xFF4FD1C5)], 'maps'),
    _StudyResource('flashcards', CupertinoIcons.rectangle_stack_fill, 'Flashcards', 'Flip to memorize fast', [Color(0xFF2D7DF6), Color(0xFF6FA8FF)], 'cards'),
    _StudyResource('formulas', CupertinoIcons.function, 'Formula Sheets', 'All key formulas in one place', [Color(0xFF7C5CFC), Color(0xFFA88BFF)], 'formulas'),
  ];


  _StudyResource get _res => _resources.firstWhere((r) => r.id == _open);
  String get _courseName => _courses.isEmpty ? '' : (_courses[_course]['title']?.toString() ?? '');

  @override
  Widget build(BuildContext context) {
    if (_loadingCourses) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 36), child: Center(child: CupertinoActivityIndicator()));
    }
    // AnimatedSize glides the popup height between the (shorter) grid and the
    // (taller/variable) detail panes; the switcher cross-fades the content.
    return AnimatedSize(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: _smoothSwitch,
        layoutBuilder: _topSwitcherLayout,
        child: _open == null ? _grid(const ValueKey('grid')) : _detail(ValueKey('d-$_open-$_course')),
      ),
    );
  }

  Widget _grid(Key key) => Column(key: key, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Course selector — real enrolled courses (hidden when none).
        if (_courses.isNotEmpty) ...[
          _Entrance(
            index: 0,
            child: SizedBox(
              height: 38,
              child: ListView(scrollDirection: Axis.horizontal, padding: EdgeInsets.zero, children: [
                for (var i = 0; i < _courses.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  _coursePill(_courses[i]['title']?.toString() ?? 'Course', i),
                ],
              ]),
            ),
          ),
          const SizedBox(height: 16),
        ],
        // Focus Timer is a built-in tool (always shown); the other cards only
        // appear when the selected course actually has that kind of material —
        // no empty tabs.
        for (var i = 0; i < _resources.length; i++)
          if (_resources[i].id == 'focus' || (!_loadingMat && _mat(_resources[i].id).isNotEmpty))
            _StudyCard(
              index: i + 1,
              item: _resources[i],
              count: _resources[i].id == 'focus' ? null : _mat(_resources[i].id).length,
              onTap: () => setState(() => _open = _resources[i].id),
            ),
        if (_loadingMat)
          const Padding(padding: EdgeInsets.symmetric(vertical: 18), child: Center(child: CupertinoActivityIndicator()))
        else if (!_resources.any((r) => r.id != 'focus' && _mat(r.id).isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _courses.isEmpty ? 'Enrol in a course to see study material' : 'No study material for $_courseName yet',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 12.5, color: _grey),
            ),
          ),
      ]);

  Widget _coursePill(String label, int i) {
    final sel = _course == i;
    return _Pressable(
      onTap: () => _selectCourse(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          gradient: sel ? _orangeGrad : null,
          color: sel ? null : _orange.withOpacity(0.07),
          borderRadius: BorderRadius.zero,
          border: Border.all(color: sel ? Colors.transparent : _cardBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(CupertinoIcons.cube_box_fill, size: 13, color: sel ? Colors.white : _orange),
          const SizedBox(width: 6),
          Text(label, style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w700, color: sel ? Colors.white : _navy)),
        ]),
      ),
    );
  }

  Widget _detail(Key key) {
    final r = _res;
    return Column(key: key, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        _Pressable(
          onTap: () => setState(() => _open = null),
          child: Container(
            width: 34, height: 34, alignment: Alignment.center,
            decoration: BoxDecoration(color: _orange.withOpacity(0.10), borderRadius: BorderRadius.zero, border: Border.all(color: _orange.withOpacity(0.25))),
            child: const Icon(CupertinoIcons.chevron_back, size: 18, color: _orange),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.title, style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: _navy)),
            Text(_courseName, style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w600, color: _orange)),
          ]),
        ),
        Container(
          width: 38, height: 38, alignment: Alignment.center,
          decoration: BoxDecoration(gradient: LinearGradient(colors: r.colors, begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.zero),
          child: Icon(r.icon, size: 19, color: Colors.white),
        ),
      ]),
      const SizedBox(height: 16),
      _content(r.id),
    ]);
  }

  Widget _content(String id) {
    // The Focus Timer is built-in and course-independent.
    if (id == 'focus') return const _FocusTimer();
    if (_loadingMat) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: CupertinoActivityIndicator()));
    }
    switch (id) {
      case 'guides':
        final items = _mat('guides');
        if (items.isEmpty) return _studyEmpty('study guides');
        return Column(children: [for (var i = 0; i < items.length; i++) _StudyExpandable(index: i, title: items[i]['title']?.toString() ?? '', points: _strs(items[i]['items']))]);
      case 'cheats':
        final items = _mat('cheats');
        if (items.isEmpty) return _studyEmpty('cheat sheets');
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (var i = 0; i < items.length; i++) _cheatCard(i, items[i]['title']?.toString() ?? '', _strs(items[i]['items']))]);
      case 'mindmap':
        final items = _mat('mindmap');
        if (items.isEmpty) return _studyEmpty('a mind map');
        final m = items.first;
        final branches = <(String, List<String>)>[
          for (final b in (m['items'] as List?) ?? const [])
            ((b as Map)['name']?.toString() ?? '', ((b['leaves'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[])),
        ];
        return _mindMap(m['title']?.toString() ?? '', branches);
      case 'flashcards':
        final items = _mat('flashcards');
        if (items.isEmpty) return _studyEmpty('flashcards');
        return _Flashcards(cards: [for (final c in items) (c['title']?.toString() ?? '', c['body']?.toString() ?? '')]);
      case 'formulas':
        final items = _mat('formulas');
        if (items.isEmpty) return _studyEmpty('formula sheets');
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (var i = 0; i < items.length; i++) _formulaCard(i, items[i]['title']?.toString() ?? '', items[i]['body']?.toString() ?? '', items[i]['note']?.toString() ?? '')]);
    }
    return const SizedBox();
  }

  // Friendly placeholder when a course has no material of this kind yet.
  Widget _studyEmpty(String what) => Container(
        padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 16),
        alignment: Alignment.center,
        child: Column(children: [
          Container(
            width: 72, height: 72, alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_orange.withOpacity(0.18), _orange.withOpacity(0.06)]),
              shape: BoxShape.circle,
              border: Border.all(color: _orange.withOpacity(0.25)),
            ),
            child: Icon(CupertinoIcons.sparkles, size: 30, color: _orange),
          ),
          const SizedBox(height: 14),
          Text(_courses.isEmpty ? 'Enrol in a course to see study material' : 'No $what for $_courseName yet',
              textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _navy)),
          const SizedBox(height: 4),
          Text(_courses.isEmpty ? '' : 'Your instructor adds these per course.',
              textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 12, color: _grey)),
        ]),
      );

  Widget _cheatCard(int i, String heading, List<String> items) => _Entrance(
        index: i,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(gradient: _cardGradient, borderRadius: BorderRadius.zero, border: Border.all(color: _cardBorder)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(CupertinoIcons.bolt_fill, size: 14, color: _orange),
              const SizedBox(width: 7),
              Text(heading, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w800, color: _navy)),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final it in items)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(gradient: LinearGradient(colors: [_orange.withOpacity(0.14), _orange.withOpacity(0.05)]), borderRadius: BorderRadius.zero, border: Border.all(color: _orange.withOpacity(0.18))),
                  child: Text(it, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _navy)),
                ),
            ]),
          ]),
        ),
      );

  Widget _mindMap(String center, List<(String, List<String>)> branches) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Entrance(
          index: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero, ),
              child: Text(center, style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white)),
            ),
          ),
        ),
        Center(child: Container(width: 2, height: 16, color: _orange.withOpacity(0.3))),
        for (var i = 0; i < branches.length; i++)
          _Entrance(
            index: i + 1,
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(gradient: _cardGradient, borderRadius: BorderRadius.zero, border: Border.all(color: _cardBorder)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(gradient: _orangeGrad, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Text(branches[i].$1, style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w700, color: _navy)),
                ]),
                const SizedBox(height: 9),
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final leaf in branches[i].$2)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: _orange.withOpacity(0.08), borderRadius: BorderRadius.zero),
                        child: Text(leaf, style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w600, color: _orange)),
                      ),
                  ]),
                ),
              ]),
            ),
          ),
      ]);

  Widget _formulaCard(int i, String name, String formula, String note) => _Entrance(
        index: i,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(gradient: _cardGradient, borderRadius: BorderRadius.zero, border: Border.all(color: _cardBorder)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w800, color: _orange)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(color: _isDark ? Colors.white.withOpacity(0.05) : Colors.white.withOpacity(0.55), borderRadius: BorderRadius.zero, border: Border.all(color: _cardBorder)),
              child: Text(formula, style: GoogleFonts.robotoMono(fontSize: 15, fontWeight: FontWeight.w600, color: _navy)),
            ),
            const SizedBox(height: 7),
            Text(note, style: GoogleFonts.inter(fontSize: 11.5, color: _grey)),
          ]),
        ),
      );
}

/// A large, colourful resource entry card (Study Guides, Flashcards, …).
class _StudyCard extends StatefulWidget {
  const _StudyCard({required this.index, required this.item, required this.onTap, this.count});
  final int index;
  final _StudyResource item;
  final VoidCallback onTap;
  final int? count;
  @override
  State<_StudyCard> createState() => _StudyCardState();
}

class _StudyCardState extends State<_StudyCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final c1 = it.colors.first;
    final c2 = it.colors.length > 1 ? it.colors.last : it.colors.first;
    final count = widget.count;
    return _Entrance(
      index: widget.index,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.only(bottom: 12),
            transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
            decoration: BoxDecoration(
              // Each card is tinted with its own colour so the hub reads as a
              // vibrant gallery rather than a flat list.
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: _isDark
                    ? [c1.withOpacity(_hover ? 0.30 : 0.20), c2.withOpacity(_hover ? 0.16 : 0.10)]
                    : [c1.withOpacity(_hover ? 0.18 : 0.12), c2.withOpacity(_hover ? 0.10 : 0.05)],
              ),
              borderRadius: BorderRadius.zero,
              border: Border.all(color: _hover ? c1.withOpacity(0.55) : c1.withOpacity(0.22), width: 1.2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.zero,
              child: Stack(children: [
                // Decorative blob bleeding off the top-right corner.
                Positioned(
                  right: -24, top: -28,
                  child: Container(
                    width: 96, height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [c1.withOpacity(0.22), c2.withOpacity(0.04)]),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(15),
                  child: Row(children: [
                    AnimatedScale(
                      scale: _hover ? 1.08 : 1.0,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutBack,
                      child: Container(
                        width: 56, height: 56, alignment: Alignment.center,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: it.colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
                          borderRadius: BorderRadius.zero,
                        ),
                        child: Icon(it.icon, size: 27, color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(it.title, style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: _navy)),
                        const SizedBox(height: 3),
                        Text(it.sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 12.5, color: _grey, height: 1.25)),
                        if (count != null) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                            decoration: BoxDecoration(color: c1.withOpacity(0.16), borderRadius: BorderRadius.zero),
                            child: Text(count == 0 ? 'Tap to add' : '$count ${it.unit}',
                                style: GoogleFonts.inter(fontSize: 10.5, fontWeight: FontWeight.w800, color: c1)),
                          ),
                        ],
                      ]),
                    ),
                    const SizedBox(width: 8),
                    AnimatedSlide(
                      offset: Offset(_hover ? 0.25 : 0, 0),
                      duration: const Duration(milliseconds: 220),
                      child: Container(
                        width: 30, height: 30, alignment: Alignment.center,
                        decoration: BoxDecoration(color: c1.withOpacity(_hover ? 0.22 : 0.12), shape: BoxShape.circle),
                        child: Icon(CupertinoIcons.chevron_right, size: 15, color: c1),
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Expandable study-guide topic (tap to reveal the bullet points).
class _StudyExpandable extends StatefulWidget {
  const _StudyExpandable({required this.index, required this.title, required this.points});
  final int index;
  final String title;
  final List<String> points;
  @override
  State<_StudyExpandable> createState() => _StudyExpandableState();
}

class _StudyExpandableState extends State<_StudyExpandable> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    return _Entrance(
      index: widget.index,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(gradient: _cardGradient, borderRadius: BorderRadius.zero, border: Border.all(color: _open ? _orange.withOpacity(0.35) : _cardBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _Pressable(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Row(children: [
                Icon(CupertinoIcons.doc_text_fill, size: 16, color: _orange),
                const SizedBox(width: 10),
                Expanded(child: Text(widget.title, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _navy))),
                AnimatedRotation(turns: _open ? 0.5 : 0, duration: const Duration(milliseconds: 200), child: Icon(CupertinoIcons.chevron_down, size: 16, color: _grey)),
              ]),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(15, 0, 15, 13),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (final p in widget.points)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 7),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Padding(padding: const EdgeInsets.only(top: 6, right: 9), child: Container(width: 5, height: 5, decoration: BoxDecoration(gradient: _orangeGrad, shape: BoxShape.circle))),
                            Expanded(child: Text(p, style: GoogleFonts.inter(fontSize: 12.5, color: _navy, height: 1.4))),
                          ]),
                        ),
                    ]),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ]),
      ),
    );
  }
}

/// Interactive Pomodoro study timer — focus / break cycles with a progress ring,
/// start/pause/reset and a session counter. Keeps students on task.
class _FocusTimer extends StatefulWidget {
  const _FocusTimer();
  @override
  State<_FocusTimer> createState() => _FocusTimerState();
}

class _FocusTimerState extends State<_FocusTimer> {
  static const _durations = [25 * 60, 5 * 60, 15 * 60]; // focus, short, long
  static const _labels = ['Focus', 'Short break', 'Long break'];
  int _mode = 0;
  int _remaining = _durations[0];
  bool _running = false;
  int _completed = 0;
  Timer? _t;

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  void _setMode(int m) {
    _t?.cancel();
    setState(() {
      _mode = m;
      _remaining = _durations[m];
      _running = false;
    });
  }

  void _toggle() {
    if (_running) {
      _t?.cancel();
      setState(() => _running = false);
      return;
    }
    if (_remaining == 0) _remaining = _durations[_mode];
    setState(() => _running = true);
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining <= 1) {
        _t?.cancel();
        setState(() {
          _remaining = 0;
          _running = false;
          if (_mode == 0) _completed++;
        });
      } else {
        setState(() => _remaining--);
      }
    });
  }

  void _reset() {
    _t?.cancel();
    setState(() {
      _remaining = _durations[_mode];
      _running = false;
    });
  }

  String get _fmt {
    final m = _remaining ~/ 60, s = _remaining % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final total = _durations[_mode];
    final progress = total == 0 ? 0.0 : (1 - _remaining / total).clamp(0.0, 1.0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        for (var i = 0; i < _labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _Pressable(
              onTap: () => _setMode(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: _mode == i ? _orangeGrad : null,
                  color: _mode == i ? null : _orange.withOpacity(0.07),
                  borderRadius: BorderRadius.zero,
                  border: Border.all(color: _mode == i ? Colors.transparent : _cardBorder),
                ),
                child: Text(_labels[i], style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: _mode == i ? Colors.white : _navy)),
              ),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 24),
      Center(
        child: SizedBox(
          width: 200,
          height: 200,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox(
              width: 200,
              height: 200,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 10,
                backgroundColor: _orange.withOpacity(0.12),
                valueColor: const AlwaysStoppedAnimation(_orange),
              ),
            ),
            Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_fmt, style: GoogleFonts.inter(fontSize: 46, fontWeight: FontWeight.w800, color: _navy)),
              Text(_labels[_mode], style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w600, color: _orange)),
            ]),
          ]),
        ),
      ),
      const SizedBox(height: 26),
      Row(children: [
        Expanded(
          child: _Pressable(
            onTap: _toggle,
            child: Container(
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero, ),
              child: Text(_running ? 'Pause' : (_remaining == 0 ? 'Restart' : 'Start'), style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        _Pressable(
          onTap: _reset,
          child: Container(
            height: 50,
            width: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: _orange.withOpacity(0.08), borderRadius: BorderRadius.zero, border: Border.all(color: _cardBorder)),
            child: const Icon(CupertinoIcons.arrow_counterclockwise, color: _orange, size: 20),
          ),
        ),
      ]),
      const SizedBox(height: 18),
      Center(child: Text('$_completed focus session${_completed == 1 ? '' : 's'} done this visit', style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w600, color: _grey))),
    ]);
  }
}

/// Interactive flashcard deck: tap to flip (3D), navigate, shuffle.
class _Flashcards extends StatefulWidget {
  const _Flashcards({required this.cards});
  final List<(String, String)> cards;
  @override
  State<_Flashcards> createState() => _FlashcardsState();
}

class _FlashcardsState extends State<_Flashcards> with SingleTickerProviderStateMixin {
  static const _pi = 3.141592653589793;
  late final AnimationController _flip = AnimationController(vsync: this, duration: const Duration(milliseconds: 460));
  // Eased so the flip accelerates then settles instead of rotating at a
  // constant (abrupt-feeling) speed.
  late final Animation<double> _flipCurved = CurvedAnimation(parent: _flip, curve: Curves.easeInOutCubic);
  late List<int> _order;
  int _pos = 0;
  bool _back = false;

  @override
  void initState() {
    super.initState();
    _order = List<int>.generate(widget.cards.length, (i) => i);
  }

  @override
  void dispose() {
    _flip.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_flip.isAnimating) return;
    _back ? _flip.reverse() : _flip.forward();
    setState(() => _back = !_back);
  }

  void _go(int delta) {
    if (widget.cards.isEmpty) return;
    setState(() {
      _pos = (_pos + delta) % _order.length;
      if (_pos < 0) _pos += _order.length;
      _back = false;
      _flip.value = 0;
    });
  }

  void _shuffle() {
    setState(() {
      _order = List<int>.from(_order)..shuffle();
      _pos = 0;
      _back = false;
      _flip.value = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.cards.isEmpty) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 22), child: Text('No flashcards yet.', textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 13, color: _grey)));
    }
    final card = widget.cards[_order[_pos]];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text('Card ${_pos + 1} of ${_order.length}', style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w600, color: _grey)),
        const Spacer(),
        _Pressable(
          onTap: _shuffle,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(CupertinoIcons.shuffle, size: 14, color: _orange),
            const SizedBox(width: 5),
            Text('Shuffle', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: _orange)),
          ]),
        ),
      ]),
      const SizedBox(height: 10),
      // The flip card.
      GestureDetector(
        onTap: _toggle,
        child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _flipCurved,
          builder: (_, __) {
            final a = _flipCurved.value * _pi;
            final showBack = a > _pi / 2;
            final face = showBack
                ? Transform(alignment: Alignment.center, transform: Matrix4.identity()..rotateY(_pi), child: _face(card.$2, true))
                : _face(card.$1, false);
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.001)
                ..rotateY(a),
              child: face,
            );
          },
        ),
        ),
      ),
      const SizedBox(height: 8),
      Center(child: Text('Tap the card to flip', style: GoogleFonts.inter(fontSize: 11.5, color: _grey))),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _navBtn('Previous', CupertinoIcons.chevron_back, () => _go(-1), filled: false)),
        const SizedBox(width: 12),
        Expanded(child: _navBtn('Next', CupertinoIcons.chevron_right, () => _go(1), filled: true)),
      ]),
    ]);
  }

  Widget _face(String text, bool isBack) => Container(
        height: 200,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: isBack
              ? const LinearGradient(colors: [Color(0xFF2D7DF6), Color(0xFF6FA8FF)], begin: Alignment.topLeft, end: Alignment.bottomRight)
              : _cardGradient,
          borderRadius: BorderRadius.zero,
          border: Border.all(color: isBack ? Colors.transparent : _orange.withOpacity(0.3), width: 1.4),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(color: isBack ? Colors.white.withOpacity(0.22) : _orange.withOpacity(0.12), borderRadius: BorderRadius.zero),
            child: Text(isBack ? 'ANSWER' : 'QUESTION', style: GoogleFonts.inter(fontSize: 9.5, fontWeight: FontWeight.w800, color: isBack ? Colors.white : _orange, letterSpacing: 0.6)),
          ),
          const SizedBox(height: 14),
          Text(text, textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w700, color: isBack ? Colors.white : _navy, height: 1.35)),
        ]),
      );

  Widget _navBtn(String label, IconData icon, VoidCallback onTap, {required bool filled}) => _Pressable(
        onTap: onTap,
        child: Container(
          height: 42, alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: filled ? _orangeGrad : null,
            color: filled ? null : _orange.withOpacity(0.08),
            borderRadius: BorderRadius.zero,
            border: filled ? null : Border.all(color: _orange.withOpacity(0.35), width: 1.5),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (!filled) Icon(icon, size: 15, color: _orange),
            if (!filled) const SizedBox(width: 6),
            Text(label, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: filled ? Colors.white : _orange)),
            if (filled) const SizedBox(width: 6),
            if (filled) Icon(icon, size: 15, color: Colors.white),
          ]),
        ),
      );
}

/// Live classes as a calendar-style agenda: sessions grouped by day, each with
/// its time, course, a LIVE-now indicator, and a Join button (Zoho link).
class _LiveAgenda extends StatelessWidget {
  const _LiveAgenda({required this.items, required this.onJoin});
  final List items;
  final void Function(Map<String, dynamic> session) onJoin;

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  String _dateKey(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = day.difference(today).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    return '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final sessions = items.map((e) => e as Map<String, dynamic>).toList()
      ..sort((a, b) => (a['starts_at']?.toString() ?? '').compareTo(b['starts_at']?.toString() ?? ''));
    final groups = <String, List<Map<String, dynamic>>>{};
    final order = <String>[];
    for (final s in sessions) {
      final dt = DateTime.tryParse(s['starts_at']?.toString() ?? '')?.toLocal();
      final key = dt == null ? 'Scheduled' : _dateKey(dt);
      groups.putIfAbsent(key, () {
        order.add(key);
        return [];
      }).add(s);
    }
    var idx = 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final k in order) ...[
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 6),
          child: Row(children: [
            Icon(CupertinoIcons.calendar, size: 14, color: _orange),
            const SizedBox(width: 7),
            Text(k, style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w800, color: _navy)),
          ]),
        ),
        for (final s in groups[k]!) _LiveCard(index: idx++, data: s, onJoin: onJoin),
      ],
    ]);
  }
}

class _LiveCard extends StatefulWidget {
  const _LiveCard({required this.index, required this.data, required this.onJoin});
  final int index;
  final Map<String, dynamic> data;
  final void Function(Map<String, dynamic> session) onJoin;

  @override
  State<_LiveCard> createState() => _LiveCardState();
}

class _LiveCardState extends State<_LiveCard> {
  bool _hover = false;

  static String _clock(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    return '$h:${d.minute.toString().padLeft(2, '0')} $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final title = d['title']?.toString() ?? 'Live class';
    final course = d['course']?.toString() ?? '';
    final url = d['join_url']?.toString() ?? '';
    final simulated = (d['kind']?.toString() ?? 'external') == 'simulated';
    final start = DateTime.tryParse(d['starts_at']?.toString() ?? '')?.toLocal();
    final end = DateTime.tryParse(d['ends_at']?.toString() ?? '')?.toLocal();
    final now = DateTime.now();
    final hardEnd = end ?? start?.add(const Duration(hours: 2));
    final live = start != null && now.isAfter(start.subtract(const Duration(minutes: 5))) && (hardEnd == null || now.isBefore(hardEnd));
    final ended = hardEnd != null && now.isAfter(hardEnd);
    // A simulated ("recorded-as-live") class shows NO clock time at all — neither
    // end (gives away the length) nor start — to keep the live illusion. Real
    // external (Zoho) sessions keep the start–end range.
    final timeLabel = simulated ? '' : (start == null ? 'TBD' : (end == null ? _clock(start) : '${_clock(start)} – ${_clock(end)}'));
    // Simulated-live sessions open in-app (no external link needed).
    final hasLink = simulated || url.isNotEmpty;

    return _Entrance(
      index: widget.index,
      child: MouseRegion(
        cursor: hasLink && !ended ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: hasLink && !ended ? () => widget.onJoin(d) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.all(13),
            transform: Matrix4.translationValues(0, _hover && hasLink && !ended ? -2 : 0, 0),
            decoration: BoxDecoration(
              gradient: live
                  ? LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_orange.withOpacity(0.16), _orange.withOpacity(0.05)])
                  : _cardGradient,
              borderRadius: BorderRadius.zero,
              border: Border.all(color: live ? _orange.withOpacity(0.45) : (_hover ? _orange.withOpacity(0.30) : _cardBorder), width: live ? 1.4 : 1),
            ),
            child: Row(children: [
              // Time / live indicator column.
              Container(
                width: 58, alignment: Alignment.center,
                child: live
                    ? Column(mainAxisSize: MainAxisSize.min, children: [
                        const _LiveDot(),
                        const SizedBox(height: 4),
                        Text('LIVE', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w800, color: _orange, letterSpacing: 0.5)),
                      ])
                    : Icon(ended ? CupertinoIcons.checkmark_circle : CupertinoIcons.videocam_fill, size: 24, color: ended ? _grey : _orange),
              ),
              Container(width: 1, height: 42, color: _line, margin: const EdgeInsets.symmetric(horizontal: 12)),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _navy, height: 1.2)),
                  const SizedBox(height: 3),
                  Text([if (course.isNotEmpty) course, if (timeLabel.isNotEmpty) timeLabel].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 11.5, color: _grey)),
                ]),
              ),
              const SizedBox(width: 10),
              // Join button (opens the Zoho link).
              if (ended)
                Text('Ended', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _grey))
              else if (!hasLink)
                Text('Link soon', style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w600, color: _grey))
              else
                _Pressable(
                  onTap: () => widget.onJoin(d),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero, ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(CupertinoIcons.videocam_fill, size: 14, color: Colors.white),
                      const SizedBox(width: 6),
                      Text(live ? 'Join now' : 'Join', style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white)),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Mounts [child] only after a short delay, showing a light spinner meanwhile.
/// Used so a heavy panel body (e.g. the forum) doesn't build during the popup's
/// Hero-morph open — keeping the "expand from the tile" animation buttery, then
/// fading the real content in.
// ignore: unused_element
class _DeferredBody extends StatefulWidget {
  const _DeferredBody({required this.child, this.delay = const Duration(milliseconds: 480)});
  final Widget child;
  final Duration delay;
  @override
  State<_DeferredBody> createState() => _DeferredBodyState();
}

class _DeferredBodyState extends State<_DeferredBody> {
  bool _ready = false;
  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOut,
        child: _ready
            ? widget.child
            : const Padding(
                key: ValueKey('deferred-loading'),
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator(color: _orange, strokeWidth: 2.5)),
              ),
      );
}

/// "Ask your mentor" hub — replaces the old peer Forum tile. Lists the student's
/// enrolled courses and their modules; tapping one opens that module's PRIVATE
/// mentor thread (the student sees only their own messages + the mentor's
/// replies). This is the single place a student communicates with their mentor.
class _MentorHelpView extends StatefulWidget {
  const _MentorHelpView({required this.auth, required this.onAsk});
  final AuthService auth;
  // (basePath, title) — basePath is /api/v1/modules/:id or /api/v1/courses/:id.
  final void Function(String basePath, String title) onAsk;

  @override
  State<_MentorHelpView> createState() => _MentorHelpViewState();
}

class _MentorHelpViewState extends State<_MentorHelpView> {
  bool _loading = true;
  List<Map<String, dynamic>> _courses = [];
  final Map<String, List<Map<String, dynamic>>> _modules = {}; // courseId -> flat modules

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cr = ApiClient.decode(await widget.auth.apiGet('/api/v1/me/courses'));
      final courses = ((cr['my_courses'] as List?) ?? []).cast<Map<String, dynamic>>();
      // Fetch each course's modules in parallel so the picker loads in one go.
      await Future.wait(courses.map((c) async {
        final id = c['id'].toString();
        try {
          final mr = ApiClient.decode(await widget.auth.apiGet('/api/v1/me/courses/$id/content'));
          _modules[id] = _flatten((mr['modules'] as List?) ?? []);
        } catch (_) {
          _modules[id] = [];
        }
      }));
      _courses = courses;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  // Flatten modules + nested sub-modules into a simple {id, title} list.
  List<Map<String, dynamic>> _flatten(List modules) {
    final out = <Map<String, dynamic>>[];
    void walk(List mods) {
      for (final m in mods) {
        final mm = m as Map<String, dynamic>;
        out.add({'id': mm['id'].toString(), 'title': mm['title']?.toString() ?? 'Module'});
        walk((mm['submodules'] as List?) ?? const []);
      }
    }
    walk(modules);
    return out;
  }

  List<Map<String, dynamic>> _mods(Map<String, dynamic> c) => _modules[c['id'].toString()] ?? const [];

  Widget _mentorRow(IconData icon, String title, VoidCallback onTap) => _HoverRow(
        onTap: onTap,
        child: Row(children: [
          Icon(icon, size: 18, color: _orange),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: _navy))),
          Icon(CupertinoIcons.chevron_forward, size: 15, color: _grey),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 44), child: Center(child: CupertinoActivityIndicator()));
    }
    final withMods = _courses.where((c) => _mods(c).isNotEmpty).toList();
    if (withMods.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 16),
        child: Text('Enroll in a course to ask your mentor a question.', textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 13, color: _grey)),
      );
    }
    final single = withMods.length == 1;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: _orange.withOpacity(0.08), border: Border.all(color: _orange.withOpacity(0.25))),
        child: Row(children: [
          Icon(CupertinoIcons.lock_fill, size: 14, color: _orange),
          const SizedBox(width: 8),
          Expanded(child: Text('Pick a topic to ask about. Your questions are private — only your mentor sees them, and they answer you back here.', style: GoogleFonts.inter(fontSize: 12, height: 1.4, color: _grey))),
        ]),
      ),
      for (final c in withMods) ...[
        // With a single course the header would just echo the tile — skip it.
        if (!single)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 4, left: 2),
            child: Text(c['title']?.toString() ?? 'Course', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w800, color: _navy)),
          ),
        // A general question not tied to any module.
        _mentorRow(
          CupertinoIcons.chat_bubble_text_fill,
          'General question',
          () => widget.onAsk('/api/v1/courses/${c['id']}', single ? 'General question' : '${c['title']} · General'),
        ),
        for (final m in _mods(c))
          _mentorRow(
            CupertinoIcons.chat_bubble_2_fill,
            m['title'] as String,
            () => widget.onAsk('/api/v1/modules/${m['id']}', m['title'] as String),
          ),
        const SizedBox(height: 12),
      ],
    ]);
  }
}

/// Discussion forum: a list of threads (newest activity first) with a composer,
/// and a tap-through thread view with chat-style posts + a reply box. Switching
/// between list and thread animates.
// ignore: unused_element
class _ForumView extends StatefulWidget {
  const _ForumView({required this.auth});
  final AuthService auth;

  @override
  State<_ForumView> createState() => _ForumViewState();
}

class _ForumViewState extends State<_ForumView> {
  late Future<List<dynamic>> _threads = _loadThreads();
  bool _composing = false;
  bool _busy = false;
  bool _coursesLoaded = false;
  List<Map<String, dynamic>> _courses = [];
  String? _courseId; // composer target; null = General
  String _filter = 'all'; // 'all' | 'general' | <courseId>
  final _title = TextEditingController();
  final _body = TextEditingController();
  // Open thread (null = list view).
  String? _openId;
  String _openTitle = '';
  bool _openCanDelete = false; // caller owns the open thread (or is staff)

  @override
  void initState() {
    super.initState();
    _ensureCourses(); // filter tabs show courses right away
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<List<dynamic>> _loadThreads() async {
    final m = ApiClient.decode(await widget.auth.apiGet('/api/v1/me/forum'));
    return (m['forum'] as List?) ?? [];
  }

  void _reload() => setState(() => _threads = _loadThreads());

  Future<void> _ensureCourses() async {
    if (_coursesLoaded) return;
    try {
      final m = ApiClient.decode(await widget.auth.apiGet('/api/v1/me/courses'));
      final list = ((m['my_courses'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      if (mounted) {
        setState(() {
          _courses = list;
          _coursesLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _coursesLoaded = true);
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  // Delete a discussion the caller owns (the backend enforces author-only).
  Future<void> _deleteThread(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        title: Text('Delete discussion?', style: GoogleFonts.inter(fontWeight: FontWeight.w700, color: _navy, fontSize: 16)),
        content: Text('This removes it (and its replies) for everyone. This cannot be undone.', style: GoogleFonts.inter(fontSize: 13, color: _grey, height: 1.35)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.inter(color: _grey, fontWeight: FontWeight.w600))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Delete', style: GoogleFonts.inter(color: _danger, fontWeight: FontWeight.w800))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      ApiClient.decode(await widget.auth.apiDelete('/api/v1/me/forum/$id'));
      if (_openId == id) setState(() => _openId = null);
      _reload();
      _toast('Discussion deleted');
    } catch (_) {
      _toast("Couldn't delete — try again");
    }
  }

  Future<void> _post() async {
    if (_title.text.trim().isEmpty || _body.text.trim().isEmpty) return _toast('Add a title and message');
    setState(() => _busy = true);
    try {
      ApiClient.decode(await widget.auth.apiPost('/api/v1/me/forum', {'course_id': _courseId ?? '', 'title': _title.text.trim(), 'body': _body.text.trim()}));
      _title.clear();
      _body.clear();
      if (mounted) setState(() {
        _composing = false;
        _busy = false;
      });
      _reload();
      _toast('Discussion posted');
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      _toast("Couldn't post — try again");
    }
  }

  @override
  Widget build(BuildContext context) {
    // No top-level AnimatedSize here: the popup's own scroll body absorbs
    // height changes (like every other panel), so the forum opens with the
    // same single, soft Hero+fade as the others — no post-open height jump.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: _smoothSwitch,
      layoutBuilder: _topSwitcherLayout,
      child: _openId == null
          ? _list(const ValueKey('list'))
          : _ForumThread(
              key: ValueKey(_openId),
              auth: widget.auth,
              threadId: _openId!,
              title: _openTitle,
              canDeleteThread: _openCanDelete,
              onDeleteThread: () => _deleteThread(_openId!),
              onBack: () {
                setState(() => _openId = null);
                _reload();
              },
            ),
    );
  }

  Widget _list(Key key) => Column(key: key, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Composer (collapsed → "Start a discussion" button).
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _composing ? _composer() : _startButton(),
        ),
        const SizedBox(height: 14),
        _filterTabs(),
        const SizedBox(height: 6),
        FutureBuilder<List<dynamic>>(
          future: _threads,
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(padding: EdgeInsets.symmetric(vertical: 34), child: Center(child: CircularProgressIndicator(color: _orange, strokeWidth: 2.5)));
            }
            final all = (snap.hasData ? snap.data! : const []).cast<Map<String, dynamic>>();
            final list = all.where(_matchesFilter).toList();
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: _smoothSwitch,
              layoutBuilder: _topSwitcherLayout,
              child: list.isEmpty
                  ? Padding(
                      key: ValueKey('empty-$_filter'),
                      padding: const EdgeInsets.symmetric(vertical: 26),
                      child: Column(children: [
                        Icon(CupertinoIcons.bubble_left_bubble_right, size: 30, color: _grey),
                        const SizedBox(height: 8),
                        Text(_filter == 'general' ? 'No general discussions yet' : 'No discussions here yet', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _navy)),
                        const SizedBox(height: 2),
                        Text('Be the first to start one!', style: GoogleFonts.inter(fontSize: 12.5, color: _grey)),
                      ]),
                    )
                  : Column(key: ValueKey('list-$_filter'), children: [for (var i = 0; i < list.length; i++) _threadCard(list[i], i)]),
            );
          },
        ),
      ]);

  bool _matchesFilter(Map<String, dynamic> m) {
    if (_filter == 'all') return true;
    final cid = m['course_id']?.toString() ?? '';
    if (_filter == 'general') return cid.isEmpty;
    return cid == _filter;
  }

  Widget _filterTabs() => SizedBox(
        height: 36,
        child: ListView(scrollDirection: Axis.horizontal, padding: EdgeInsets.zero, children: [
          _filterChip('All', 'all', CupertinoIcons.square_stack_3d_up_fill),
          const SizedBox(width: 8),
          _filterChip('General', 'general', CupertinoIcons.globe),
          for (final c in _courses) ...[
            const SizedBox(width: 8),
            _filterChip(c['title']?.toString() ?? 'Course', c['id']?.toString() ?? '', CupertinoIcons.book_fill),
          ],
        ]),
      );

  Widget _filterChip(String label, String value, IconData icon) {
    final sel = _filter == value;
    return _Pressable(
      onTap: () => setState(() => _filter = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          gradient: sel ? _orangeGrad : null,
          color: sel ? null : _orange.withOpacity(0.07),
          borderRadius: BorderRadius.zero,
          border: Border.all(color: sel ? Colors.transparent : _cardBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: sel ? Colors.white : _orange),
          const SizedBox(width: 6),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w700, color: sel ? Colors.white : _navy)),
        ]),
      ),
    );
  }

  Widget _startButton() => _Pressable(
        onTap: () {
          setState(() => _composing = true);
          _ensureCourses();
        },
        child: Container(
          height: 44, alignment: Alignment.center,
          decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero, ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(CupertinoIcons.plus_bubble_fill, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            Text('Start a discussion', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
          ]),
        ),
      );

  Widget _composer() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(gradient: _cardGradient, borderRadius: BorderRadius.zero, border: Border.all(color: _orange.withOpacity(0.30)), ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(CupertinoIcons.plus_bubble_fill, size: 16, color: _orange),
            const SizedBox(width: 8),
            Text('New discussion', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w800, color: _navy)),
            const Spacer(),
            _Pressable(onTap: () => setState(() => _composing = false), child: Icon(CupertinoIcons.xmark_circle_fill, size: 20, color: _grey)),
          ]),
          const SizedBox(height: 12),
          if (!_coursesLoaded)
            const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Center(child: CupertinoActivityIndicator()))
          else ...[
            Text('Post to', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: _grey, letterSpacing: 0.3)),
            const SizedBox(height: 6),
            SizedBox(
              height: 34,
              child: ListView(scrollDirection: Axis.horizontal, padding: EdgeInsets.zero, children: [
                _coursePill('General', _courseId == null, () => setState(() => _courseId = null)),
                for (final c in _courses) ...[
                  const SizedBox(width: 8),
                  _coursePill(c['title']?.toString() ?? 'Course', _courseId == c['id']?.toString(), () => setState(() => _courseId = c['id']?.toString())),
                ],
              ]),
            ),
            const SizedBox(height: 10),
            _field(_title, 'Title', maxLines: 1),
            const SizedBox(height: 10),
            _field(_body, 'Share your question or thought…', maxLines: 4),
            const SizedBox(height: 12),
            _Pressable(
              onTap: _busy ? () {} : _post,
              child: Container(
                height: 46, alignment: Alignment.center,
                decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero, ),
                child: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                    : Text('Post discussion', style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            ),
          ],
        ]),
      );

  Widget _coursePill(String label, bool sel, VoidCallback onTap) => _Pressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            gradient: sel ? _orangeGrad : null,
            color: sel ? null : _orange.withOpacity(0.07),
            borderRadius: BorderRadius.zero,
            border: Border.all(color: sel ? Colors.transparent : _cardBorder),
          ),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? Colors.white : _navy)),
        ),
      );

  Widget _field(TextEditingController c, String hint, {int maxLines = 1}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: _isDark ? Colors.white.withOpacity(0.05) : Colors.white.withOpacity(0.55), borderRadius: BorderRadius.zero, border: Border.all(color: _cardBorder)),
        child: TextField(
          controller: c,
          maxLines: maxLines,
          style: GoogleFonts.inter(fontSize: 13.5, color: _navy),
          decoration: InputDecoration(border: InputBorder.none, isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 12), hintText: hint, hintStyle: GoogleFonts.inter(fontSize: 13, color: _grey.withOpacity(0.7))),
        ),
      );

  Widget _threadCard(Map<String, dynamic> m, int index) {
    final title = m['title']?.toString() ?? 'Discussion';
    final author = m['author']?.toString() ?? 'Someone';
    final course = m['course']?.toString() ?? '';
    final snippet = m['snippet']?.toString() ?? '';
    final avatar = m['avatar']?.toString() ?? '';
    final replies = ((m['replies'] ?? 0) as num).toInt();
    final initials = author.trim().isNotEmpty ? author.trim()[0].toUpperCase() : '?';
    return _Entrance(
      index: index,
      child: _ForumHoverCard(
        onTap: () => setState(() {
          _openId = m['id']?.toString();
          _openTitle = title;
          _openCanDelete = m['can_delete'] == true;
        }),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _avatarBox(avatar, 40, initials),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 14.5, fontWeight: FontWeight.w700, color: _navy, height: 1.25))),
                if (m['can_delete'] == true)
                  _Pressable(
                    onTap: () => _deleteThread(m['id']?.toString() ?? ''),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, top: 1),
                      child: Icon(CupertinoIcons.trash, size: 15, color: _danger.withOpacity(0.8)),
                    ),
                  ),
              ]),
              if (snippet.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(snippet, maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 12.5, color: _grey, height: 1.3)),
              ],
              const SizedBox(height: 8),
              Row(children: [
                if (course.isNotEmpty)
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: _orange.withOpacity(0.10), borderRadius: BorderRadius.zero),
                      child: Text(course, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 10.5, fontWeight: FontWeight.w700, color: _orange)),
                    ),
                  ),
                const Spacer(),
                Icon(CupertinoIcons.chat_bubble_2_fill, size: 13, color: _grey),
                const SizedBox(width: 4),
                Text('$replies', style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w700, color: _grey)),
                const SizedBox(width: 10),
                Text(_StudentHomeState._fmtAt(m['last_at']?.toString()), style: GoogleFonts.inter(fontSize: 10.5, color: _grey)),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Hover-lift glass card used for forum thread rows.
class _ForumHoverCard extends StatefulWidget {
  const _ForumHoverCard({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback onTap;
  @override
  State<_ForumHoverCard> createState() => _ForumHoverCardState();
}

class _ForumHoverCardState extends State<_ForumHoverCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.all(13),
            transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
            decoration: BoxDecoration(
              gradient: _cardGradient,
              borderRadius: BorderRadius.zero,
              border: Border.all(color: _hover ? _orange.withOpacity(0.40) : _cardBorder),
            ),
            child: widget.child,
          ),
        ),
      );
}

/// A single forum thread: chat-style posts + a reply composer.
class _ForumThread extends StatefulWidget {
  const _ForumThread({super.key, required this.auth, required this.threadId, required this.title, required this.onBack, this.canDeleteThread = false, this.onDeleteThread});
  final AuthService auth;
  final String threadId;
  final String title;
  final VoidCallback onBack;
  final bool canDeleteThread; // caller owns the discussion (or is staff)
  final VoidCallback? onDeleteThread;

  @override
  State<_ForumThread> createState() => _ForumThreadState();
}

class _ForumThreadState extends State<_ForumThread> {
  late Future<Map<String, dynamic>> _future = _load();
  final _reply = TextEditingController();
  bool _sending = false;

  Future<Map<String, dynamic>> _load() async => ApiClient.decode(await widget.auth.apiGet('/api/v1/me/forum/${widget.threadId}'));

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  Future<bool> _confirm(String title, String msg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        title: Text(title, style: GoogleFonts.inter(fontWeight: FontWeight.w700, color: _navy, fontSize: 16)),
        content: Text(msg, style: GoogleFonts.inter(fontSize: 13, color: _grey, height: 1.35)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.inter(color: _grey, fontWeight: FontWeight.w600))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Delete', style: GoogleFonts.inter(color: _danger, fontWeight: FontWeight.w800))),
        ],
      ),
    );
    return ok == true;
  }

  // Delete one of the caller's own messages (backend enforces author-only). If
  // it was the last message, the discussion is removed and we return to the list.
  Future<void> _deletePost(String id) async {
    if (!await _confirm('Delete message?', 'This removes your message for everyone. This cannot be undone.')) return;
    try {
      final res = ApiClient.decode(await widget.auth.apiDelete('/api/v1/me/forum/posts/$id'));
      if (res['thread_deleted'] == true) {
        widget.onBack(); // discussion is now empty → back to the list (it reloads)
      } else if (mounted) {
        setState(() => _future = _load());
      }
      _toast('Message deleted');
    } catch (_) {
      _toast("Couldn't delete — try again");
    }
  }

  Future<void> _send() async {
    final body = _reply.text.trim();
    if (body.isEmpty) return;
    setState(() => _sending = true);
    try {
      ApiClient.decode(await widget.auth.apiPost('/api/v1/me/forum/${widget.threadId}/reply', {'body': body}));
      _reply.clear();
      if (mounted) setState(() {
        _sending = false;
        _future = _load();
      });
    } catch (_) {
      if (mounted) setState(() => _sending = false);
      _toast("Couldn't send reply");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Back + title.
      Row(children: [
        _Pressable(
          onTap: widget.onBack,
          child: Container(
            width: 34, height: 34, alignment: Alignment.center,
            decoration: BoxDecoration(color: _orange.withOpacity(0.10), borderRadius: BorderRadius.zero, border: Border.all(color: _orange.withOpacity(0.25))),
            child: const Icon(CupertinoIcons.chevron_back, size: 18, color: _orange),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: _navy))),
        // Delete the whole discussion (only the owner / staff see this).
        if (widget.canDeleteThread && widget.onDeleteThread != null)
          _Pressable(
            onTap: widget.onDeleteThread!,
            child: Container(
              width: 34, height: 34, alignment: Alignment.center,
              decoration: BoxDecoration(color: _danger.withOpacity(0.10), borderRadius: BorderRadius.zero, border: Border.all(color: _danger.withOpacity(0.25))),
              child: Icon(CupertinoIcons.trash, size: 16, color: _danger),
            ),
          ),
      ]),
      const SizedBox(height: 14),
      FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(padding: EdgeInsets.symmetric(vertical: 30), child: Center(child: CircularProgressIndicator(color: _orange, strokeWidth: 2.5)));
          }
          final posts = (snap.data?['posts'] as List?) ?? [];
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < posts.length; i++) _post(posts[i] as Map<String, dynamic>, i),
          ]);
        },
      ),
      const SizedBox(height: 12),
      // Reply composer.
      Row(children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(gradient: _cardGradient, borderRadius: BorderRadius.zero, border: Border.all(color: _cardBorder)),
            child: TextField(
              controller: _reply,
              minLines: 1,
              maxLines: 4,
              style: GoogleFonts.inter(fontSize: 13.5, color: _navy),
              decoration: InputDecoration(border: InputBorder.none, isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 12), hintText: 'Write a reply…', hintStyle: GoogleFonts.inter(fontSize: 13, color: _grey.withOpacity(0.7))),
            ),
          ),
        ),
        const SizedBox(width: 10),
        _Pressable(
          onTap: _sending ? () {} : _send,
          child: Container(
            width: 46, height: 46, alignment: Alignment.center,
            decoration: BoxDecoration(gradient: _orangeGrad, shape: BoxShape.circle, ),
            child: _sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                : const Icon(CupertinoIcons.paperplane_fill, size: 18, color: Colors.white),
          ),
        ),
      ]),
    ]);
  }

  Widget _post(Map<String, dynamic> p, int index) {
    final author = p['author']?.toString() ?? 'Someone';
    final body = p['body']?.toString() ?? '';
    final avatar = p['avatar']?.toString() ?? '';
    final staff = p['staff'] == true;
    final initials = author.trim().isNotEmpty ? author.trim()[0].toUpperCase() : '?';
    return _Entrance(
      index: index,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _avatarBox(avatar, 36, initials),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(author, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w700, color: _navy))),
                if (staff) ...[
                  const SizedBox(width: 6),
                  Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero), child: Text('STAFF', style: GoogleFonts.inter(fontSize: 8, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.5))),
                ],
                const Spacer(),
                Text(_StudentHomeState._fmtAt(p['at']?.toString()), style: GoogleFonts.inter(fontSize: 10, color: _grey)),
                // Delete this reply (only the author / staff see this).
                if (p['can_delete'] == true) ...[
                  const SizedBox(width: 8),
                  _Pressable(
                    onTap: () => _deletePost(p['id']?.toString() ?? ''),
                    child: Icon(CupertinoIcons.trash, size: 13, color: _danger.withOpacity(0.75)),
                  ),
                ],
              ]),
              const SizedBox(height: 5),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                decoration: BoxDecoration(
                  gradient: _cardGradient,
                  borderRadius: const BorderRadius.only(topLeft: Radius.zero, topRight: Radius.zero, bottomLeft: Radius.zero, bottomRight: Radius.zero),
                  border: Border.all(color: _cardBorder),
                ),
                child: Text(body, style: GoogleFonts.inter(fontSize: 13, color: _navy, height: 1.45)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Leaderboard with an "Overall" (total XP) tab plus one tab per enrolled
/// course (ranked by XP earned in that course). Switching tabs animates.
// ignore: unused_element
class _LeaderboardView extends StatefulWidget {
  const _LeaderboardView({required this.auth});
  final AuthService auth;

  @override
  State<_LeaderboardView> createState() => _LeaderboardViewState();
}

class _LeaderboardViewState extends State<_LeaderboardView> {
  List<Map<String, dynamic>> _courses = [];
  String? _courseId; // null = Overall
  late Future<List<dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
    _loadCourses();
  }

  Future<void> _loadCourses() async {
    try {
      final m = ApiClient.decode(await widget.auth.apiGet('/api/v1/me/courses'));
      final list = ((m['my_courses'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      if (mounted) setState(() => _courses = list);
    } catch (_) {}
  }

  Future<List<dynamic>> _fetch() async {
    final path = _courseId == null ? '/api/v1/me/leaderboard' : '/api/v1/me/leaderboard?course_id=$_courseId';
    final m = ApiClient.decode(await widget.auth.apiGet(path));
    return (m['leaderboard'] as List?) ?? [];
  }

  void _select(String? id) {
    if (id == _courseId) return;
    setState(() {
      _courseId = id;
      _future = _fetch();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Tab selector: Overall + a chip per enrolled course.
      SizedBox(
        height: 38,
        child: ListView(scrollDirection: Axis.horizontal, padding: EdgeInsets.zero, children: [
          _tab('Overall', _courseId == null, () => _select(null)),
          for (final c in _courses) ...[
            const SizedBox(width: 8),
            _tab(c['title']?.toString() ?? 'Course', _courseId == c['id']?.toString(), () => _select(c['id']?.toString())),
          ],
        ]),
      ),
      const SizedBox(height: 14),
      FutureBuilder<List<dynamic>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(padding: EdgeInsets.symmetric(vertical: 34), child: Center(child: CircularProgressIndicator(color: _orange, strokeWidth: 2.5)));
          }
          if (snap.hasError || !snap.hasData) {
            return Padding(padding: const EdgeInsets.symmetric(vertical: 22), child: Text("Couldn't load — pull again later.", textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 13, color: _grey)));
          }
          final rows = snap.data!;
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: _smoothSwitch,
            layoutBuilder: _topSwitcherLayout,
            child: rows.isEmpty
                ? Padding(key: const ValueKey('empty'), padding: const EdgeInsets.symmetric(vertical: 22), child: Text('No ranked learners here yet — finish a lesson to climb the board!', textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 13, color: _grey)))
                : Column(
                    key: ValueKey(_courseId ?? 'overall'),
                    children: [for (var i = 0; i < rows.length; i++) _LeaderRow(index: i, data: rows[i] as Map<String, dynamic>)],
                  ),
          );
        },
      ),
    ]);
  }

  Widget _tab(String label, bool selected, VoidCallback onTap) => _Pressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            gradient: selected ? _orangeGrad : _cardGradient,
            borderRadius: BorderRadius.zero,
            border: Border.all(color: selected ? Colors.transparent : _cardBorder),
          ),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w700, color: selected ? Colors.white : _navy)),
        ),
      );
}

/// One leaderboard entry: medal/rank badge, avatar, name + course, XP + lessons.
/// Top-3 get gold/silver/bronze medals; the caller's row glows. Staggered in.
class _LeaderRow extends StatefulWidget {
  const _LeaderRow({required this.index, required this.data});
  final int index;
  final Map<String, dynamic> data;

  @override
  State<_LeaderRow> createState() => _LeaderRowState();
}

class _LeaderRowState extends State<_LeaderRow> {
  bool _hover = false;

  // Gold / silver / bronze gradients for the top three; null otherwise.
  static List<Color>? _medal(int rank) {
    switch (rank) {
      case 1:
        return [const Color(0xFFFFD75E), const Color(0xFFF5A623)];
      case 2:
        return [const Color(0xFFD6DCE3), const Color(0xFF9AA4AE)];
      case 3:
        return [const Color(0xFFE9A777), const Color(0xFFC57B3C)];
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final rank = ((d['rank'] ?? widget.index + 1) as num).toInt();
    final name = d['name']?.toString().trim().isNotEmpty == true ? d['name'].toString() : 'Learner';
    final course = d['course']?.toString() ?? '';
    final xp = ((d['xp'] ?? 0) as num).toInt();
    final lessons = ((d['lessons'] ?? 0) as num).toInt();
    final isMe = d['is_me'] == true;
    final avatar = d['avatar']?.toString() ?? '';
    final initials = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final medal = _medal(rank);

    return _Entrance(
      index: widget.index,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          transform: Matrix4.translationValues(0, _hover ? -1 : 0, 0),
          decoration: BoxDecoration(
            gradient: isMe
                ? LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_orange.withOpacity(0.18), _orange.withOpacity(0.06)])
                : _cardGradient,
            borderRadius: BorderRadius.zero,
            border: Border.all(color: isMe ? _orange.withOpacity(0.55) : (_hover ? _orange.withOpacity(0.30) : _cardBorder), width: isMe ? 1.5 : 1),
          ),
          child: Row(children: [
            // Rank / medal badge.
            SizedBox(
              width: 34,
              child: medal != null
                  ? Container(
                      width: 32, height: 32, alignment: Alignment.center,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: medal, begin: Alignment.topLeft, end: Alignment.bottomRight),
                        shape: BoxShape.circle,
                      ),
                      child: Text('$rank', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
                    )
                  : Center(child: Text('$rank', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _grey))),
            ),
            const SizedBox(width: 10),
            _avatarBox(avatar, 40, initials),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _navy))),
                  if (isMe) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero),
                      child: Text('YOU', style: GoogleFonts.inter(fontSize: 8.5, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.5)),
                    ),
                  ],
                ]),
                const SizedBox(height: 2),
                Row(children: [
                  Icon(CupertinoIcons.book_fill, size: 11, color: _grey),
                  const SizedBox(width: 4),
                  Flexible(child: Text(course.isNotEmpty ? course : 'Getting started', maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 11.5, color: _grey))),
                ]),
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('$xp XP', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w800, color: _orange)),
              Text('$lessons ${lessons == 1 ? 'lesson' : 'lessons'}', style: GoogleFonts.inter(fontSize: 10.5, color: _grey)),
            ]),
          ]),
        ),
      ),
    );
  }
}

// --- Calendar agenda: groups schedule / deadlines / activities by day. -----

({IconData icon, Color color, String label}) _calKind(String kind) {
  switch (kind) {
    case 'session':
      return (icon: CupertinoIcons.videocam_fill, color: _orange, label: 'Live class');
    case 'assessment_due':
      return (icon: CupertinoIcons.doc_text_fill, color: const Color(0xFFE0A12A), label: 'Deadline');
    case 'announcement':
      return (icon: CupertinoIcons.bell_fill, color: const Color(0xFF2D7DF6), label: 'Activity');
    default:
      return (icon: CupertinoIcons.calendar, color: _orange, label: 'Event');
  }
}

String _timeLabel(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
}


const _monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Live month calendar — dots per day for classes / deadlines / activities; tap
/// a day to see its agenda. Smooth month + day-selection transitions, themed.
class _CalendarView extends StatefulWidget {
  const _CalendarView({required this.items, this.onOpenSession});
  final List items;
  // Tapping a live-class entry opens it (in-app live room / external link).
  final void Function(Map<String, dynamic> session)? onOpenSession;

  @override
  State<_CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends State<_CalendarView> {
  final Map<String, List<Map<String, dynamic>>> _byDay = {};
  late DateTime _month;
  late DateTime _selected;
  int _dir = 1;

  String _k(DateTime d) => '${d.year}-${d.month}-${d.day}';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selected = DateTime(now.year, now.month, now.day);
    _month = DateTime(now.year, now.month);
    for (final e in widget.items) {
      final m = e as Map<String, dynamic>;
      final dt = DateTime.tryParse(m['at']?.toString() ?? '')?.toLocal();
      if (dt == null) continue;
      _byDay.putIfAbsent(_k(DateTime(dt.year, dt.month, dt.day)), () => []).add({...m, '_dt': dt});
    }
  }

  void _shift(int delta) => setState(() {
        _dir = delta;
        _month = DateTime(_month.year, _month.month + delta);
      });

  static const _amber = Color(0xFFE0A12A);
  static const _blue = Color(0xFF2D7DF6);

  @override
  Widget build(BuildContext context) {
    // Visible-month tallies for the summary chips.
    int cls = 0, dl = 0, act = 0;
    _byDay.forEach((key, evs) {
      final p = key.split('-');
      if (int.parse(p[0]) == _month.year && int.parse(p[1]) == _month.month) {
        for (final m in evs) {
          final kind = m['kind']?.toString() ?? 'event';
          if (kind == 'session') {
            cls++;
          } else if (kind == 'assessment_due') {
            dl++;
          } else {
            act++;
          }
        }
      }
    });
    final now = DateTime.now();
    final atToday = _month.year == now.year && _month.month == now.month && _selected.year == now.year && _selected.month == now.month && _selected.day == now.day;
    final selEvs = [...(_byDay[_k(_selected)] ?? const <Map<String, dynamic>>[])]..sort((a, b) => (a['_dt'] as DateTime).compareTo(b['_dt'] as DateTime));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        _navBtn(CupertinoIcons.chevron_left, () => _shift(-1)),
        Expanded(child: Center(child: Text('${_monthNames[_month.month - 1]} ${_month.year}', style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w800, color: _navy)))),
        _navBtn(CupertinoIcons.chevron_right, () => _shift(1)),
      ]),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: _sumChip('Classes', cls, _orange, CupertinoIcons.videocam_fill)),
        const SizedBox(width: 10),
        Expanded(child: _sumChip('Deadlines', dl, _amber, CupertinoIcons.doc_text_fill)),
        const SizedBox(width: 10),
        Expanded(child: _sumChip('Activities', act, _blue, CupertinoIcons.bell_fill)),
      ]),
      const SizedBox(height: 16),
      Row(children: _weekdayNames.map((w) => Expanded(child: Center(child: Text(w, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: _grey))))).toList()),
      const SizedBox(height: 6),
      ClipRect(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(position: Tween<Offset>(begin: Offset(0.12 * _dir, 0), end: Offset.zero).animate(a), child: child),
          ),
          child: KeyedSubtree(key: ValueKey('${_month.year}-${_month.month}'), child: _grid()),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: atToday
            ? const SizedBox(height: 14)
            : Padding(padding: const EdgeInsets.only(top: 10, bottom: 6), child: Center(child: _todayBtn(now))),
      ),
      Divider(color: _cardBorder, height: 1),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: Text('${_weekdayNames[(_selected.weekday - 1) % 7]}, ${_monthNames[_selected.month - 1]} ${_selected.day}', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _navy))),
        if (selEvs.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(color: _orange.withOpacity(0.12), borderRadius: BorderRadius.zero),
            child: Text('${selEvs.length} ${selEvs.length == 1 ? 'event' : 'events'}', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700, color: _orange)),
          ),
      ]),
      const SizedBox(height: 12),
      AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: _smoothSwitch,
          layoutBuilder: _topSwitcherLayout,
          child: KeyedSubtree(key: ValueKey(_k(_selected)), child: _agenda(selEvs)),
        ),
      ),
      _history(),
    ]);
  }

  // Finished live classes, newest first — a running history below the calendar.
  Widget _history() {
    final past = widget.items
        .whereType<Map>()
        .where((m) => m['kind']?.toString() == 'session' && m['ended'] == true)
        .map((m) => m.cast<String, dynamic>())
        .toList()
      ..sort((a, b) => (DateTime.tryParse(b['at']?.toString() ?? '') ?? DateTime(0))
          .compareTo(DateTime.tryParse(a['at']?.toString() ?? '') ?? DateTime(0)));
    if (past.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 20),
      Divider(color: _cardBorder, height: 1),
      const SizedBox(height: 14),
      Row(children: [
        Icon(CupertinoIcons.clock_fill, size: 15, color: _grey),
        const SizedBox(width: 8),
        Text('Live class history', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w800, color: _navy)),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(color: _grey.withOpacity(0.14), borderRadius: BorderRadius.zero),
          child: Text('${past.length}', style: GoogleFonts.inter(fontSize: 10.5, fontWeight: FontWeight.w700, color: _grey)),
        ),
      ]),
      const SizedBox(height: 10),
      for (final m in past.take(40)) _historyTile(m),
    ]);
  }

  Widget _historyTile(Map<String, dynamic> m) {
    final dt = DateTime.tryParse(m['at']?.toString() ?? '')?.toLocal();
    final when = dt == null ? '' : '${_monthNames[dt.month - 1]} ${dt.day}, ${dt.year}';
    final course = m['course']?.toString() ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: _surface, border: Border.all(color: _cardBorder)),
      child: Row(children: [
        Container(
          width: 36, height: 36, alignment: Alignment.center,
          decoration: BoxDecoration(color: _grey.withOpacity(0.12), shape: BoxShape.circle),
          child: Icon(CupertinoIcons.checkmark_alt, size: 18, color: _grey),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m['title']?.toString() ?? 'Live class', maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w700, color: _navy)),
          const SizedBox(height: 2),
          Text([if (course.isNotEmpty) course, when].where((e) => e.isNotEmpty).join(' · '), style: GoogleFonts.inter(fontSize: 11.5, color: _grey)),
        ])),
        Text('Ended', style: GoogleFonts.inter(fontSize: 10.5, fontWeight: FontWeight.w700, color: _grey)),
      ]),
    );
  }

  Widget _navBtn(IconData ic, VoidCallback onTap) => _Pressable(
        onTap: onTap,
        child: Container(
          width: 38, height: 38, alignment: Alignment.center,
          decoration: BoxDecoration(color: _orange.withOpacity(0.10), borderRadius: BorderRadius.zero),
          child: Icon(ic, size: 18, color: _orange),
        ),
      );

  Widget _sumChip(String label, int n, Color color, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(color: color.withOpacity(0.10), borderRadius: BorderRadius.zero, border: Border.all(color: color.withOpacity(0.22))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: n.toDouble()),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (_, v, __) => Text('${v.round()}', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
            ),
          ]),
          const SizedBox(height: 2),
          Text(label, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500, color: _grey)),
        ]),
      );

  Widget _todayBtn(DateTime now) => _Pressable(
        onTap: () => setState(() {
          _dir = _month.isBefore(DateTime(now.year, now.month)) ? 1 : -1;
          _month = DateTime(now.year, now.month);
          _selected = DateTime(now.year, now.month, now.day);
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(color: _orange.withOpacity(0.12), borderRadius: BorderRadius.zero),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(CupertinoIcons.calendar_today, size: 14, color: _orange),
            const SizedBox(width: 6),
            Text('Today', style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w700, color: _orange)),
          ]),
        ),
      );

  Widget _grid() {
    final first = DateTime(_month.year, _month.month, 1);
    final lead = (first.weekday - 1) % 7; // Monday-start
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final cells = <DateTime?>[];
    for (var i = 0; i < lead; i++) cells.add(null);
    for (var d = 1; d <= days; d++) cells.add(DateTime(_month.year, _month.month, d));
    while (cells.length % 7 != 0) cells.add(null);
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 7) {
      rows.add(Row(children: [for (var j = 0; j < 7; j++) Expanded(child: _cell(cells[i + j]))]));
    }
    return Column(children: rows);
  }

  Widget _cell(DateTime? d) {
    if (d == null) return const SizedBox(height: 48);
    final now = DateTime.now();
    final isToday = d.year == now.year && d.month == now.month && d.day == now.day;
    final isSel = d == _selected;
    final evs = _byDay[_k(d)] ?? const [];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _selected = d),
      child: AnimatedScale(
        scale: isSel ? 1.06 : 1.0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutBack,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: 48,
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            gradient: isSel ? _orangeGrad : null,
            color: isSel ? null : (isToday ? _orange.withOpacity(0.12) : Colors.transparent),
            borderRadius: BorderRadius.zero,
            border: isToday && !isSel ? Border.all(color: _orange.withOpacity(0.6), width: 1.4) : null,
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('${d.day}', style: GoogleFonts.inter(fontSize: 13, fontWeight: isSel || isToday ? FontWeight.w700 : FontWeight.w500, color: isSel ? Colors.white : _navy)),
            const SizedBox(height: 3),
            SizedBox(
              height: 5,
              child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                for (final m in evs.take(3))
                  Container(width: 5, height: 5, margin: const EdgeInsets.symmetric(horizontal: 1), decoration: BoxDecoration(color: isSel ? Colors.white : _calKind(m['kind']?.toString() ?? 'event').color, shape: BoxShape.circle)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _agenda(List<Map<String, dynamic>> evs) {
    if (evs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(children: [
          Icon(CupertinoIcons.calendar, size: 30, color: _grey.withOpacity(0.7)),
          const SizedBox(height: 8),
          Text('Nothing scheduled', style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w600, color: _navy)),
          const SizedBox(height: 2),
          Text('Enjoy the free time, or browse the catalog.', textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 12, color: _grey)),
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < evs.length; i++)
        _Entrance(
          index: i,
          child: Builder(builder: (_) {
            final m = evs[i];
            final k = _calKind(m['kind']?.toString() ?? 'event');
            final dt = m['_dt'] as DateTime;
            final course = m['course']?.toString() ?? '';
            // Live-class entries are tappable → open the session.
            final isSession = (m['kind']?.toString() ?? '') == 'session' && (m['id']?.toString().isNotEmpty ?? false);
            final card = Container(
              margin: const EdgeInsets.only(bottom: 10),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(gradient: _cardGradient, borderRadius: BorderRadius.zero, border: Border.all(color: _cardBorder), ),
              child: IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(width: 4, color: k.color),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(width: 40, height: 40, alignment: Alignment.center, decoration: BoxDecoration(color: k.color.withOpacity(0.14), borderRadius: BorderRadius.zero), child: Icon(k.icon, size: 19, color: k.color)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(m['title']?.toString() ?? 'Event', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: _navy)),
                            const SizedBox(height: 3),
                            Row(children: [
                              Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: k.color.withOpacity(0.12), borderRadius: BorderRadius.zero), child: Text(k.label, style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: k.color))),
                              if (course.isNotEmpty) ...[const SizedBox(width: 6), Flexible(child: Text(course, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 12, color: _grey)))],
                            ]),
                          ]),
                        ),
                        const SizedBox(width: 8),
                        Text(_timeLabel(dt), style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _grey)),
                      ]),
                    ),
                  ),
                ]),
              ),
            );
            if (isSession && widget.onOpenSession != null) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onOpenSession!({'id': m['id'], 'kind': m['live_kind'], 'title': m['title'], 'join_url': m['join_url']}),
                child: card,
              );
            }
            return card;
          }),
        ),
    ]);
  }
}

Widget _help(String q, String a) => Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF0F0F0)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 10, height: 10, margin: const EdgeInsets.only(top: 5, right: 14), decoration: BoxDecoration(color: _navy, shape: BoxShape.circle)),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(q, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: _navy)),
          const SizedBox(height: 3),
          Text(a, style: GoogleFonts.inter(fontSize: 12, color: _grey, height: 1.4)),
        ])),
      ]),
    );

Widget _field(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFFAAAAAA), fontWeight: FontWeight.w600, letterSpacing: 0.5)),
        const SizedBox(height: 5),
        TextFormField(
          initialValue: value,
          style: GoogleFonts.inter(fontSize: 14, color: _navy),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: const BorderSide(color: Color(0xFFEEEEEE), width: 1.5)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: const BorderSide(color: _orange, width: 1.5)),
          ),
        ),
      ]),
    );

Widget _orangeButton(String label, VoidCallback onTap) => _Pressable(
      onTap: onTap,
      child: Container(
        width: double.infinity, height: 44, alignment: Alignment.center,
        decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero),
        child: Text(label, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
      ),
    );


// ---- Small interactive widgets ---------------------------------------------

/// Live AI / tech news feed (right sidebar). Polls `/api/v1/news` on mount and
/// every few minutes, showing loading / fallback / data states. Keeps the exact
/// card chrome — only the list content is now real and tappable.
///
/// When [scrollable] (wide layout) the header + "View All" button stay pinned
/// and only the news list scrolls; otherwise it shrink-wraps and the page
/// scrolls as a whole.
class _AiNewsCard extends StatefulWidget {
  const _AiNewsCard({required this.auth, required this.scrollable});
  final AuthService auth;
  final bool scrollable;

  @override
  State<_AiNewsCard> createState() => _AiNewsCardState();
}

class _AiNewsCardState extends State<_AiNewsCard> {
  List<_News>? _items; // null until the first load resolves
  bool _failed = false;
  bool _refreshing = false;
  Timer? _poll; // refetches fresh headlines
  Timer? _ticker; // ticks the "x min ago" labels + LIVE windows
  final Set<String> _knownUrls = {}; // every URL seen so far
  Set<String> _newUrls = {}; // URLs that arrived on the latest poll
  bool _hover = false; // thin border highlights on hover

  @override
  void initState() {
    super.initState();
    _load();
    // Pull fresh headlines every 45s (backend auto-refreshes ~every 90s)…
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => _load());
    // …and re-render every 20s so the relative times & LIVE badges stay live
    // even between fetches.
    _ticker = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_refreshing) return;
    if (mounted) setState(() => _refreshing = true);
    try {
      // 'all' — the full AI + tech mix across every domain (per-source capped
      // server-side so no single feed dominates).
      final res = await widget.auth.apiGet('/api/v1/news?category=all');
      final data = ApiClient.decode(res);
      final list = ((data['news'] as List?) ?? [])
          .map((e) => _News.fromJson(e as Map<String, dynamic>))
          .where((n) => n.title.isNotEmpty && n.url.isNotEmpty)
          .toList();
      if (!mounted) return;
      // Flag headlines that are new since the last poll (skip the first load so
      // we don't light up the whole list on open).
      final firstLoad = _items == null;
      final incoming = list.map((n) => n.url).toSet();
      final fresh = firstLoad ? <String>{} : incoming.difference(_knownUrls);
      _knownUrls.addAll(incoming);
      setState(() {
        _items = list;
        _newUrls = fresh;
        _failed = false;
        _refreshing = false;
      });
    } catch (_) {
      if (!mounted) return;
      // Keep any previously-loaded items; only flag failure when we have none.
      setState(() {
        _failed = true;
        _refreshing = false;
      });
    }
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    // New tab on web, external browser on mobile.
    await launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: _glass(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      border: _hover ? _orange : _orange.withOpacity(0.28),
      borderWidth: _hover ? 1.4 : 1,
      tint: _hover ? Color.alphaBlend(_orange.withOpacity(0.06), _glassFill) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: widget.scrollable ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Row(children: [
            Icon(CupertinoIcons.sparkles, size: 18, color: _orange),
            const SizedBox(width: 8),
            Text('UPDATE ', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: _navy)),
            Text('LIVE AI NEWS', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: _orange)),
            const Spacer(),
            // "N new" badge appears when fresh headlines land, then fades next poll.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (child, a) => FadeTransition(opacity: a, child: ScaleTransition(scale: a, child: child)),
              child: _newUrls.isEmpty
                  ? const SizedBox.shrink()
                  : Padding(
                      key: ValueKey(_newUrls.length),
                      padding: const EdgeInsets.only(right: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero, ),
                        child: Text('${_newUrls.length} NEW', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.5)),
                      ),
                    ),
            ),
            _livePill(),
          ]),
          const SizedBox(height: 10),
          if (widget.scrollable) Expanded(child: _body()) else _body(),
        ],
      ),
      ),
    );
  }

  // Loading / fallback / list — the only part that varies by state.
  Widget _body() {
    final items = _items;
    if (items == null && !_failed) return _statusBox(loading: true);
    if ((items == null || items.isEmpty)) return _statusBox(loading: false);

    final rows = <Widget>[
      for (var i = 0; i < items.length; i++) _newsRow(items[i], last: i == items.length - 1, isNew: _newUrls.contains(items[i].url)),
    ];
    if (widget.scrollable) {
      return ListView(padding: EdgeInsets.zero, children: rows);
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  Widget _statusBox({required bool loading}) {
    final child = loading
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: 34),
            child: Center(child: CircularProgressIndicator(color: _orange, strokeWidth: 2.5)),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 30),
            child: Column(children: [
              Icon(CupertinoIcons.wifi_slash, size: 28, color: _grey),
              const SizedBox(height: 8),
              Text('Live news unavailable', textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: _navy)),
              const SizedBox(height: 2),
              Text('Pull again in a moment.', textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 12, color: _grey)),
            ]),
          );
    // Keep a consistent height in the scrollable (wide) layout.
    return widget.scrollable ? Center(child: child) : child;
  }

  // Pulsing, tappable LIVE pill — tap to refresh now; shows a spinner while
  // fetching.
  Widget _livePill() => GestureDetector(
        onTap: _load,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: _orange.withOpacity(0.12), borderRadius: BorderRadius.zero),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _refreshing
                ? const SizedBox(width: 9, height: 9, child: CircularProgressIndicator(strokeWidth: 1.6, color: _orange))
                : const _LiveDot(),
            const SizedBox(width: 5),
            Text('LIVE', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w800, color: _orange, letterSpacing: 0.5)),
          ]),
        ),
      );

  Widget _newsRow(_News n, {required bool last, bool isNew = false}) {
    final live = n.isLive;
    return InkWell(
      onTap: () => _open(n.url),
      // Newly-arrived headlines get a soft orange wash that fades out on the
      // next poll (AnimatedContainer smooths the tint → transparent).
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOut,
        padding: const EdgeInsets.fromLTRB(8, 11, 8, 11),
        margin: const EdgeInsets.symmetric(vertical: 1),
        decoration: BoxDecoration(
          gradient: isNew
              ? LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: [_orange.withOpacity(0.14), _orange.withOpacity(0.03)])
              : null,
          borderRadius: BorderRadius.zero,
          border: last || isNew ? null : Border(bottom: BorderSide(color: _line)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 56, height: 56, alignment: Alignment.center,
            decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_orange.withOpacity(0.16), _orange.withOpacity(0.06)]), borderRadius: BorderRadius.zero),
            child: Icon(n.icon, size: 26, color: _orange),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // NEW badge for just-arrived items, then LIVE for recent ones,
              // otherwise the source name.
              if (isNew)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero),
                    child: Text('NEW', style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.5)),
                  ),
                ])
              else if (live)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const _LiveDot(),
                  const SizedBox(width: 5),
                  Text('LIVE', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w800, color: _orange, letterSpacing: 0.5)),
                ])
              else
                Text(n.source.toUpperCase(), style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w800, color: _orange, letterSpacing: 0.5)),
              const SizedBox(height: 4),
              Text(n.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w700, color: _navy, height: 1.3)),
              const SizedBox(height: 4),
              Text(
                [n.source, if (n.ago.isNotEmpty) n.ago].join(' · '),
                style: GoogleFonts.inter(fontSize: 11.5, color: _grey),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Icon(CupertinoIcons.chevron_right, size: 16, color: _grey),
          ),
        ]),
      ),
    );
  }
}

/// A softly pulsing dot for the LIVE badge — signals the feed is live.
class _LiveDot extends StatefulWidget {
  const _LiveDot();
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 850))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final t = _c.value;
        return Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
            color: Color.lerp(_orange.withOpacity(0.45), _orange, t),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}

/// Transparent route for the popup card: keeps the dashboard visible behind so
/// the Hero can morph the tile into the card, and lets us blur/dim the
/// background inside the page (animated with the route).
class _PanelRoute<T> extends PageRouteBuilder<T> {
  _PanelRoute({required Widget child})
      : super(
          opaque: false,
          barrierDismissible: false,
          transitionDuration: const Duration(milliseconds: 480),
          reverseTransitionDuration: const Duration(milliseconds: 380),
          pageBuilder: (ctx, anim, sec) => child,
          // Motion is handled by the Hero + the in-page animations.
          transitionsBuilder: (ctx, anim, sec, c) => c,
        );

  // Bracket the route's lifetime so the animated backdrop pauses while open.
  @override
  void install() {
    super.install();
    _panelDepth.value++;
  }

  @override
  void dispose() {
    if (_panelDepth.value > 0) _panelDepth.value--;
    super.dispose();
  }
}

/// Shared fade + gentle vertical slide for in-popup view changes (grid↔detail,
/// thread open, tab switch …). Eased so the incoming pane decelerates in.
Widget _smoothSwitch(Widget child, Animation<double> a) => FadeTransition(
      opacity: a,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.035), end: Offset.zero)
            .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );

/// Top-aligned stack for [AnimatedSwitcher] so the panes grow from the top
/// (matching the scroll body) and an enclosing [AnimatedSize] can glide the
/// height between differently-sized panes instead of snapping.
Widget _topSwitcherLayout(Widget? current, List<Widget> previous) =>
    Stack(alignment: Alignment.topCenter, children: <Widget>[...previous, if (current != null) current]);

/// Straight-line, eased Hero rect interpolation for the tile → panel expansion.
/// Flutter's default Material Hero uses a curved *arc* path driven by a *linear*
/// animation — on a square-tile → wide-header reshape that swoops and
/// starts/stops abruptly, which reads as "rough". A direct lerp with an
/// easeOutCubic curve gives a smooth, decelerating morph along a clean path.
RectTween _smoothHeroRect(Rect? begin, Rect? end) => _SmoothRectTween(begin: begin, end: end);

class _SmoothRectTween extends RectTween {
  _SmoothRectTween({super.begin, super.end});
  @override
  Rect? lerp(double t) => Rect.lerp(begin, end, Curves.easeOutCubic.transform(t.clamp(0.0, 1.0)));
}

/// iOS App-Store-style expanding card. A [Hero] morphs the tapped tile into the
/// gradient header; the dashboard stays blurred/dimmed behind; the body fades
/// in. Reverses smoothly on pop.
class _HeroPanelModal extends StatelessWidget {
  const _HeroPanelModal({required this.icon, required this.title, required this.sub, required this.body, this.heroTag, this.compact = false});
  final IconData icon;
  final String title;
  final String sub;
  final List<Widget> body;
  final String? heroTag;
  // Compact = a small content-sized centred card (confirm dialogs); otherwise
  // the big 97% sheet.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final anim = ModalRoute.of(context)!.animation!;
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (ctx, mode, _) {
        _isDark = mode == ThemeMode.dark || (mode == ThemeMode.system && MediaQuery.platformBrightnessOf(ctx) == Brightness.dark);
        final size = MediaQuery.of(ctx).size;
        // Keyboard height (0 when hidden). The sheet shrinks by this so its form
        // stays above the keyboard and the focused field scrolls into view.
        final kb = MediaQuery.of(ctx).viewInsets.bottom;
        // Phone = edge-to-edge sheet (kept in sync with _card's `fill`).
        final phone = size.shortestSide < 600;
        // Own ScaffoldMessenger so SnackBars from panel content (settings, 2FA,
        // push) render on top of the panel instead of behind it (the dashboard's
        // messenger sits under this pushed route). Transparent Scaffold; the panel
        // does its own keyboard inset handling, so don't double it.
        return ScaffoldMessenger(child: Scaffold(backgroundColor: Colors.transparent, resizeToAvoidBottomInset: false, body: Stack(children: [
          // Blur + dim the dashboard behind (animated with the route). Tap to close.
          // Isolated in a RepaintBoundary so the heavy blur layer is cached and
          // the card's own glass blur (which samples this) doesn't force the
          // whole dashboard to re-blur on every in-popup frame.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(ctx).maybePop(),
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: anim,
                  builder: (_, __) {
                    // Ramp the blur in over the first part of the open so the
                    // expensive sigma sweep is brief, then hold steady. Lower
                    // max sigma (14 vs 22) keeps it light on web.
                    final v = Curves.easeOut.transform(anim.value.clamp(0.0, 1.0));
                    return BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 14 * v, sigmaY: 14 * v),
                      child: Container(color: Colors.black.withOpacity(0.34 * v)),
                    );
                  },
                ),
              ),
            ),
          ),
          // Reserve the keyboard's space, then place the sheet in what's left —
          // top-aligned on phones (so it fills, edge-to-edge) and centred on
          // tablets/desktop.
          Padding(
            padding: EdgeInsets.only(bottom: kb),
            child: Align(
              alignment: (phone && !compact) ? Alignment.topCenter : Alignment.center,
              child: compact
                  ? Padding(
                      padding: EdgeInsets.symmetric(horizontal: size.width < 480 ? 24 : 0, vertical: 40),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: 420, maxHeight: (size.height - kb) * 0.85),
                        child: _card(ctx, anim),
                      ),
                    )
                  : SizedBox(
                      // Phones: edge-to-edge, aligned to the screen border (kept in
                      // sync with _card's `fill`). Tablets / laptops / desktops:
                      // cap the sheet and centre it so content isn't stretched wide.
                      width: phone ? size.width : (size.width * 0.97).clamp(0.0, 1180.0),
                      height: phone ? (size.height - kb) : ((size.height - kb) * 0.97).clamp(0.0, 960.0),
                      child: _card(ctx, anim),
                    ),
            ),
          ),
        ])));
      },
    );
  }

  Widget _card(BuildContext ctx, Animation<double> anim) {
    // On phones a full panel fills the screen edge-to-edge (flush, square
    // corners); on tablets/desktops it stays a centred, rounded, floating card.
    final mq = MediaQuery.of(ctx);
    final bool fill = !compact && mq.size.shortestSide < 600;
    // The gradient header is the shared element that morphs from the tile.
    final header = Material(
      type: MaterialType.transparency,
      child: Container(
        // When the panel meets the screen top, inset the header by the device
        // safe area (Dynamic Island / notch) so the title clears it.
        padding: EdgeInsets.fromLTRB(14, 16 + (fill ? mq.padding.top : 0), 18, 16),
        // Solid, pinned title bar (no glass) so nothing shows through it as the
        // body scrolls; the accent is used only on the icon/back chip.
        decoration: BoxDecoration(
          color: _isDark ? const Color(0xFF1B1D25) : Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.zero),
          border: Border(bottom: BorderSide(color: _cardBorder)),
        ),
        child: Row(children: [
          _Pressable(
            onTap: () => Navigator.of(ctx).maybePop(),
            child: Container(
              width: 34, height: 34, alignment: Alignment.center,
              decoration: BoxDecoration(color: _orange.withOpacity(0.12), borderRadius: BorderRadius.zero, border: Border.all(color: _orange.withOpacity(0.25))),
              child: const Icon(CupertinoIcons.chevron_back, size: 20, color: _orange),
            ),
          ),
          const SizedBox(width: 12),
          Icon(icon, size: 26, color: _orange),
          const SizedBox(width: 12),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w800, color: _navy)),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 12, color: _grey)),
            ]),
          ),
        ]),
      ),
    );

    return Material(
      type: MaterialType.transparency,
      child: KeyedSubtree(
        key: ValueKey(_isDark),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.zero,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.zero,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: Container(
                width: double.infinity,
                // Near-solid card so text is fully legible (only a hint of frost).
                decoration: BoxDecoration(
                  color: _isDark ? const Color(0xFF1B1D25) : Colors.white,
                  borderRadius: BorderRadius.zero,
                  border: Border.all(color: _isDark ? Colors.white.withOpacity(0.12) : _cardBorder, width: 1),
                ),
                child: Column(
                  mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
              heroTag != null ? Hero(tag: heroTag!, createRectTween: _smoothHeroRect, child: header) : header,
              Flexible(
                fit: compact ? FlexFit.loose : FlexFit.tight,
                child: FadeTransition(
                  opacity: CurvedAnimation(parent: anim, curve: const Interval(0.35, 1.0, curve: Curves.easeOut)),
                  child: SlideTransition(
                    position: Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero)
                        .animate(CurvedAnimation(parent: anim, curve: const Interval(0.35, 1.0, curve: Curves.easeOutCubic))),
                    // The body scrolls and runs its own in-popup transitions;
                    // isolate it so those repaints never reach the glass layers.
                    child: RepaintBoundary(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(20, 18, 20, 22 + (fill ? mq.padding.bottom : 0)),
                        // Keep the content as a readable centred column on wide
                        // tablets/laptops instead of stretching edge-to-edge.
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 760),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Uint8List? _decodeDataUri(String d) {
  try {
    return base64Decode(d.substring(d.indexOf(',') + 1));
  } catch (_) {
    return null;
  }
}

/// A square (rounded) profile picture. [avatar] is '' / 'p:N' (preset) or a
/// 'data:' URI (uploaded photo). Shows a camera badge when [editable].
Widget _avatarBox(String avatar, double size, String initials, {bool editable = false}) {
  final bytes = avatar.startsWith('data:') ? _decodeDataUri(avatar) : null;
  Widget face;
  if (bytes != null) {
    face = Container(
      width: size, height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        border: Border.all(color: Colors.white, width: 3),
        image: DecorationImage(image: MemoryImage(bytes), fit: BoxFit.cover),
      ),
    );
  } else {
    final idx = avatar.startsWith('p:') ? (int.tryParse(avatar.substring(2)) ?? 0) : 0;
    final a = _avatars[idx.clamp(0, _avatars.length - 1)];
    face = Container(
      width: size, height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: a.colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.zero,
        border: Border.all(color: Colors.white, width: 3),
      ),
      child: a.emoji.isEmpty
          ? Text(initials, style: GoogleFonts.inter(fontSize: size * 0.40, fontWeight: FontWeight.w800, color: Colors.white))
          : Text(a.emoji, style: TextStyle(fontSize: size * 0.52)),
    );
  }
  return Stack(clipBehavior: Clip.none, children: [
    face,
    if (editable)
      Positioned(
        right: -3, bottom: -3,
        child: Container(
          width: 26, height: 26, alignment: Alignment.center,
          decoration: BoxDecoration(gradient: _orangeGrad, shape: BoxShape.circle, border: Border.all(color: _surface, width: 2)),
          child: const Icon(CupertinoIcons.camera_fill, size: 12, color: Colors.white),
        ),
      ),
  ]);
}

/// A glowing progress line: a rounded track, an orange gradient fill, and a
/// bright circular "spark" thumb sitting at the fill point. Used for every
/// course / lesson progress bar so they all share one attractive look.
/// [value] is 0..1 and animates up from 0 on first paint.
class _GlowProgress extends StatelessWidget {
  const _GlowProgress({required this.value, this.height = 8});
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final target = value.clamp(0.0, 1.0);
    final thumb = height + 14; // diameter of the spark thumb
    return SizedBox(
      height: thumb,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: target),
        duration: const Duration(milliseconds: 850),
        curve: Curves.easeOutCubic,
        builder: (context, t, __) {
          return LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final fillW = (w * t).clamp(0.0, w);
              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  // Track.
                  Container(
                    height: height,
                    decoration: BoxDecoration(
                      color: _isDark ? const Color(0xFF2C2F37) : const Color(0xFFF0EBE8),
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                  // Gradient fill.
                  Container(
                    height: height,
                    width: fillW,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFFFF9A5E), _orange, Color(0xFFE8421F)]),
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                  // Glowing spark thumb at the fill point.
                  if (t > 0.001)
                    Positioned(
                      top: 0, bottom: 0,
                      left: (fillW - thumb / 2).clamp(0.0, w - thumb),
                      child: Container(
                        width: thumb, height: thumb, alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.auto_awesome, size: thumb * 0.52, color: _orange),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Staggered fade + slide entrance for list items.
class _Entrance extends StatefulWidget {
  const _Entrance({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  late final Animation<double> _fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween<Offset>(begin: const Offset(0, 0.10), end: Offset.zero).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    // Lighter stagger, capped so long lists still finish quickly (no item
    // waits more than ~360ms before starting).
    final delay = (45 * widget.index).clamp(0, 360);
    Future.delayed(Duration(milliseconds: delay), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(child: FadeTransition(opacity: _fade, child: SlideTransition(position: _slide, child: widget.child)));
}

/// A "continue where you left off" card: course cover with a play overlay, the
/// next lesson (activity) to resume, progress bar, and a one-tap Continue.
class _ResumeCard extends StatefulWidget {
  const _ResumeCard({required this.index, required this.data, required this.onContinue});
  final int index;
  final Map<String, dynamic> data;
  final void Function(Map<String, dynamic> lesson) onContinue;

  @override
  State<_ResumeCard> createState() => _ResumeCardState();
}

class _ResumeCardState extends State<_ResumeCard> {
  bool _hover = false;

  static const _covers = [
    [_orange, Color(0xFFFF7A4D)],
    [Color(0xFFFF7A4D), Color(0xFFFFB347)],
    [Color(0xFFF0653C), Color(0xFFFF9166)],
    [Color(0xFFE8542E), Color(0xFFFF7A4D)],
  ];

  // Seconds → m:ss (or h:mm:ss).
  static String _fmtClock(int s) {
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : m.toString();
    return h > 0 ? '$h:$mm:${sec.toString().padLeft(2, '0')}' : '$mm:${sec.toString().padLeft(2, '0')}';
  }

  ({IconData icon, String label}) _kind(String type) {
    switch (type) {
      case 'video':
        return (icon: CupertinoIcons.play_rectangle_fill, label: 'VIDEO');
      case 'link':
        return (icon: CupertinoIcons.link, label: 'LINK');
      case 'file':
        return (icon: CupertinoIcons.doc_fill, label: 'FILE');
      default:
        return (icon: CupertinoIcons.doc_text_fill, label: 'LESSON');
    }
  }

  // 84×84 cover: admin image if set, else a gradient — with a play overlay.
  Widget _thumb(List<Color> cover) {
    final url = widget.data['image_url']?.toString() ?? '';
    Widget bg;
    Widget? im;
    if (url.isNotEmpty) {
      if (url.startsWith('data:')) {
        final bytes = _decodeDataUri(url);
        if (bytes != null) im = Image.memory(bytes, width: 84, height: 84, fit: BoxFit.cover);
      } else if (url.startsWith('http')) {
        im = Image.network(url, width: 84, height: 84, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox());
      }
    }
    bg = im ??
        Container(
          width: 84, height: 84,
          decoration: BoxDecoration(gradient: LinearGradient(colors: cover, begin: Alignment.topLeft, end: Alignment.bottomRight)),
        );
    return ClipRRect(
      borderRadius: BorderRadius.zero,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox(width: 84, height: 84, child: bg),
        // Dim + play button overlay.
        Container(width: 84, height: 84, color: Colors.black.withOpacity(0.18)),
        AnimatedScale(
          scale: _hover ? 1.12 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: Container(
            width: 34, height: 34, alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.92), shape: BoxShape.circle, ),
            child: const Icon(CupertinoIcons.play_fill, size: 16, color: _orange),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final cover = _covers[widget.index % _covers.length];
    final course = d['course']?.toString() ?? 'Course';
    final lesson = d['title']?.toString() ?? 'Next lesson';
    final module = d['module']?.toString() ?? '';
    final type = d['type']?.toString() ?? 'text';
    final percent = ((d['percent'] ?? 0) as num).toInt();
    final done = ((d['done'] ?? 0) as num).toInt();
    final total = ((d['total'] ?? 0) as num).toInt();
    final position = ((d['position'] ?? 0) as num).toInt();
    final k = _kind(type);
    final pct = (percent / 100).clamp(0.0, 1.0);

    void go() => widget.onContinue({'id': d['lesson_id'], 'title': lesson, 'type': type, 'url': d['url'], 'position': position});

    return _Entrance(
      index: widget.index,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        // The card itself is NOT tappable — the video resumes only from the
        // "Continue" button below, nowhere else.
        child: GestureDetector(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.all(14),
            transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
            decoration: BoxDecoration(
              gradient: _cardGradient,
              borderRadius: BorderRadius.zero,
              border: Border.all(color: _hover ? _orange.withOpacity(0.40) : _cardBorder, width: 1),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _thumb(cover),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(course.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 10.5, fontWeight: FontWeight.w800, color: _orange, letterSpacing: 0.4)),
                    const SizedBox(height: 3),
                    Row(children: [
                      Icon(k.icon, size: 13, color: _grey),
                      const SizedBox(width: 5),
                      Text(k.label, style: GoogleFonts.inter(fontSize: 9.5, fontWeight: FontWeight.w800, color: _grey, letterSpacing: 0.5)),
                      if (position > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: _orange.withOpacity(0.12), borderRadius: BorderRadius.zero),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(CupertinoIcons.arrow_counterclockwise, size: 9, color: _orange),
                            const SizedBox(width: 3),
                            Text('Resume ${_fmtClock(position)}', style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w800, color: _orange)),
                          ]),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 4),
                    Text(lesson, maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 14.5, fontWeight: FontWeight.w700, color: _navy, height: 1.25)),
                    if (module.isNotEmpty)
                      Padding(padding: const EdgeInsets.only(top: 2), child: Text(module, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 11.5, color: _grey))),
                  ]),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Text('$done/$total lessons', style: GoogleFonts.inter(fontSize: 11.5, color: _grey)),
                const Spacer(),
                Text('$percent%', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: _orange)),
              ]),
              const SizedBox(height: 7),
              _GlowProgress(value: pct, height: 6),
              const SizedBox(height: 12),
              // Compact, pill-shaped — the ONLY thing that resumes the video.
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _Pressable(
                    onTap: go,
                    child: Container(
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        gradient: _orangeGrad,
                        borderRadius: BorderRadius.zero,
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(CupertinoIcons.play_fill, color: Colors.white, size: 14),
                        const SizedBox(width: 7),
                        Text('Continue', style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.white)),
                      ]),
                    ),
                  ),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A rich course card: gradient cover, animated progress bar, hover lift.
class _CourseCard extends StatefulWidget {
  const _CourseCard({required this.index, required this.title, required this.done, required this.total, required this.percent, required this.onOpen, this.grade, this.imageUrl});
  final int index;
  final String title;
  final int done;
  final int total;
  final int percent;
  final int? grade; // quiz grade % (null until the student has taken a quiz)
  final VoidCallback onOpen;
  final String? imageUrl; // admin-set cover (data URI or URL)

  @override
  State<_CourseCard> createState() => _CourseCardState();
}

class _CourseCardState extends State<_CourseCard> {
  bool _hover = false;

  // A subtle per-card cover gradient (warm hues that stay on-theme).
  static const _covers = [
    [_orange, Color(0xFFFF7A4D)],
    [Color(0xFFFF7A4D), Color(0xFFFFB347)],
    [Color(0xFFF0653C), Color(0xFFFF9166)],
    [Color(0xFFE8542E), Color(0xFFFF7A4D)],
  ];

  // The 58×58 cover: admin image if present, otherwise a gradient + book glyph.
  Widget _cover(List<Color> cover) {
    final url = widget.imageUrl;
    Widget? im;
    if (url != null && url.isNotEmpty) {
      if (url.startsWith('data:')) {
        try {
          im = Image.memory(base64Decode(url.substring(url.indexOf(',') + 1)), width: 58, height: 58, fit: BoxFit.cover);
        } catch (_) {}
      } else if (url.startsWith('http')) {
        im = Image.network(url, width: 58, height: 58, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _glyphCover(cover));
      }
    }
    if (im != null) return ClipRRect(borderRadius: BorderRadius.zero, child: im);
    return _glyphCover(cover);
  }

  Widget _glyphCover(List<Color> cover) => Container(
        width: 58, height: 58, alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: cover, begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.zero,
        ),
        child: const Icon(CupertinoIcons.book_fill, size: 24, color: Colors.white),
      );

  @override
  Widget build(BuildContext context) {
    final cover = _covers[widget.index % _covers.length];
    final pct = (widget.percent / 100).clamp(0.0, 1.0);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(14),
          transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
          decoration: BoxDecoration(
            gradient: _cardGradient,
            borderRadius: BorderRadius.zero,
            border: Border.all(color: _hover ? _orange.withOpacity(0.40) : _cardBorder, width: 1),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Admin cover image if set, else a gradient cover with the book glyph.
            _cover(cover),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: _navy))),
                  AnimatedSlide(
                    offset: Offset(_hover ? 0.2 : 0, 0),
                    duration: const Duration(milliseconds: 200),
                    child: Icon(CupertinoIcons.chevron_right, size: 15, color: _orange.withOpacity(_hover ? 0.9 : 0.35)),
                  ),
                ]),
                const SizedBox(height: 7),
                Row(children: [
                  Icon(CupertinoIcons.book, size: 13, color: _grey),
                  const SizedBox(width: 4),
                  Text('${widget.done}/${widget.total} lessons', style: GoogleFonts.inter(fontSize: 12, color: _grey)),
                  if (widget.grade != null) ...[
                    const SizedBox(width: 10),
                    Icon(CupertinoIcons.chart_bar_alt_fill, size: 12, color: _green),
                    const SizedBox(width: 3),
                    Text('${widget.grade}%', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: _green)),
                  ],
                  const Spacer(),
                  Text('${widget.percent}% done', style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w700, color: _orange)),
                ]),
                const SizedBox(height: 9),
                _GlowProgress(value: pct, height: 7),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// One square option tile: a colored graphic (emoji) plus the option name.
/// No rounded corners. Scales slightly on hover/press.
class _GridCell extends StatefulWidget {
  const _GridCell({required this.tile, required this.size, required this.onTap});
  final _Tile tile;
  final double size;
  // Reports the tile's global centre so the panel can grow from it (macOS-style).
  final void Function(Offset center) onTap;

  @override
  State<_GridCell> createState() => _GridCellState();
}

class _GridCellState extends State<_GridCell> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tile;
    final s = widget.size;
    final active = _hover || _down;
    // Smooth lift on hover, gentle squash on press (no overshoot/bounce).
    final scale = _down ? 0.96 : (_hover ? 1.06 : 1.0);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: () {
          final box = context.findRenderObject() as RenderBox?;
          widget.onTap(box != null ? box.localToGlobal(box.size.center(Offset.zero)) : Offset.zero);
        },
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            width: s, height: s,
            alignment: Alignment.center,
            padding: EdgeInsets.all(s * 0.08),
            // Flat solid orange tile — no peach, no glow, no sheen. Squared.
            // Hover just deepens the orange a touch (no shadow bloom).
            decoration: BoxDecoration(
              color: active ? const Color(0xFFFF6A2C) : _orange,
            ),
            // The icon is a fixed size on every tile (proportional to the cell,
            // so it's uniform across the grid) — only the label scales to fit, so
            // a long label never shrinks its icon. This keeps the icons even.
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon nudges up and grows a touch on hover.
                AnimatedSlide(
                  offset: _hover ? const Offset(0, -0.05) : Offset.zero,
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  child: AnimatedScale(
                    scale: _hover ? 1.12 : 1.0,
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    child: Icon(t.icon, color: Colors.white, size: (s * 0.40).clamp(24.0, 52.0)),
                  ),
                ),
                SizedBox(height: s * 0.05),
                SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Text(t.label,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Danger accent for destructive actions (kept warm/on-theme).
const _danger = Color(0xFFE0453C);

/// Full Settings experience: Appearance (theme mode, accent colour, font size)
/// and Security (update password, login activity, logout all devices).
class _SettingsView extends StatefulWidget {
  const _SettingsView({required this.auth, required this.onLogout});
  final AuthService auth;
  final VoidCallback onLogout;

  @override
  State<_SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<_SettingsView> {
  // Expansion + form state.
  bool _pwOpen = false;
  bool _actOpen = false;
  bool _savingPw = false;
  String? _pwErr; // inline password error (shown in the form, not a toast)
  bool _pwSaved = false; // inline success after a password change
  final _cur = TextEditingController();
  final _new = TextEditingController();
  final _conf = TextEditingController();
  final Set<TextEditingController> _shownPw = {}; // password fields revealed
  List<dynamic>? _devices; // null until first load
  String? _currentDeviceId; // which listed device is the one we're on now
  int _maxDevices = 2; // effective slot limit; 0 = unlimited (staff)

  Color get _ac => accentNotifier.value;
  LinearGradient get _acGrad => LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_ac, Color.lerp(_ac, Colors.white, 0.22)!]);

  @override
  void initState() {
    super.initState();
    themeNotifier.addListener(_r);
    accentNotifier.addListener(_r);
    textScaleNotifier.addListener(_r);
  }

  void _r() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    themeNotifier.removeListener(_r);
    accentNotifier.removeListener(_r);
    textScaleNotifier.removeListener(_r);
    for (final c in [_cur, _new, _conf]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _savePassword() async {
    final cur = _cur.text, nw = _new.text, cf = _conf.text;
    // Validation errors render inline in the form — a SnackBar here would slide
    // up behind the panel and never be seen.
    if (cur.isEmpty || nw.isEmpty) return _setPwErr('Fill in all fields');
    if (nw.length < 8) return _setPwErr('New password must be at least 8 characters');
    if (nw != cf) return _setPwErr('New passwords do not match');
    setState(() {
      _savingPw = true;
      _pwErr = null;
      _pwSaved = false;
    });
    try {
      ApiClient.decode(await widget.auth.apiPost('/api/v1/me/password', {'current_password': cur, 'new_password': nw}));
      _cur.clear();
      _new.clear();
      _conf.clear();
      if (mounted) setState(() => _pwSaved = true); // keep the form open so the ✓ shows
    } on ApiException catch (e) {
      if (mounted) setState(() => _pwErr = e.message);
    } catch (_) {
      if (mounted) setState(() => _pwErr = "Couldn't update password");
    } finally {
      if (mounted) setState(() => _savingPw = false);
    }
  }

  void _setPwErr(String m) => setState(() {
        _pwErr = m;
        _pwSaved = false;
      });

  Future<void> _loadDevices() async {
    try {
      final m = ApiClient.decode(await widget.auth.apiGet('/api/v1/devices'));
      if (mounted) {
        setState(() {
          _devices = (m['devices'] as List?) ?? [];
          _currentDeviceId = m['current_device_id']?.toString();
          _maxDevices = ((m['max_devices'] ?? 2) as num).toInt();
        });
      }
    } catch (_) {
      if (mounted) setState(() => _devices = []);
    }
  }

  String _deviceSummary() {
    final n = _devices?.length ?? 0;
    if (_maxDevices <= 0) return '$n active device${n == 1 ? '' : 's'} · no limit on your account';
    return 'Using $n of $_maxDevices device slot${_maxDevices == 1 ? '' : 's'}';
  }

  // A friendly name from platform/model (raw model when we have it).
  String _deviceName(String platform, String model) {
    final p = platform.toLowerCase();
    if (model.isNotEmpty && model.toLowerCase() != p) return model;
    if (p.contains('android')) return 'Android device';
    if (p.contains('ios')) return 'iPhone / iPad';
    if (p.contains('web')) return 'Web browser';
    if (platform.isNotEmpty) return platform[0].toUpperCase() + platform.substring(1);
    return 'Unknown device';
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Entrance(
        index: 0,
        child: _section('Appearance', CupertinoIcons.paintbrush_fill, [
          _themeRow(),
          _div(),
          _fontRow(),
        ]),
      ),
      const SizedBox(height: 14),
      _Entrance(
        index: 2,
        child: _section('Security', CupertinoIcons.lock_shield_fill, [
          _passwordRow(),
          _div(),
          _activityRow(),
        ]),
      ),
    ]);
  }

  // ---- Building blocks ------------------------------------------------------

  Widget _section(String title, IconData icon, List<Widget> rows) => Container(
        decoration: BoxDecoration(
          gradient: _cardGradient,
          borderRadius: BorderRadius.zero,
          border: Border.all(color: _cardBorder),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 15, 16, 6),
            child: Row(children: [
              Icon(icon, size: 16, color: _ac),
              const SizedBox(width: 8),
              Text(title, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w800, color: _navy)),
            ]),
          ),
          ...rows,
        ]),
      );

  Widget _div() => Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 16), color: _line);

  Widget _iconChip(IconData icon, {Color? color}) {
    final c = color ?? _ac;
    return Container(
      width: 34, height: 34, alignment: Alignment.center,
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [c.withOpacity(0.22), c.withOpacity(0.08)]), borderRadius: BorderRadius.zero),
      child: Icon(icon, size: 16, color: c),
    );
  }

  // A control row: icon + title/sub, with [control] beneath.
  Widget _ctrlRow(IconData icon, String title, String sub, Widget control) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _iconChip(icon),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _navy)),
              Text(sub, style: GoogleFonts.inter(fontSize: 11.5, color: _grey)),
            ])),
          ]),
          const SizedBox(height: 10),
          control,
        ]),
      );

  // A tappable row (for expandable / action items).
  Widget _tapRow(IconData icon, String title, String sub, VoidCallback onTap, {Widget? trailing, Color? tint}) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(children: [
            _iconChip(icon, color: tint),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: tint ?? _navy)),
              Text(sub, style: GoogleFonts.inter(fontSize: 11.5, color: _grey)),
            ])),
            const SizedBox(width: 8),
            trailing ?? Icon(CupertinoIcons.chevron_right, size: 15, color: _grey),
          ]),
        ),
      );

  Widget _seg(List<String> labels, int sel, void Function(int) onTap) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: _ac.withOpacity(0.08), borderRadius: BorderRadius.zero),
        child: Row(children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: _Pressable(
                onTap: () => onTap(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: sel == i ? _acGrad : null,
                    borderRadius: BorderRadius.zero,
                  ),
                  child: Text(labels[i], style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w700, color: sel == i ? Colors.white : _navy)),
                ),
              ),
            ),
        ]),
      );

  // ---- Appearance -----------------------------------------------------------

  Widget _themeRow() {
    final mode = themeNotifier.value;
    final sel = mode == ThemeMode.system ? 0 : (mode == ThemeMode.light ? 1 : 2);
    return _ctrlRow(CupertinoIcons.circle_righthalf_fill, 'Theme', 'System, light or dark', _seg(['System', 'Light', 'Dark'], sel, (i) {
      setTheme(i == 0 ? ThemeMode.system : (i == 1 ? ThemeMode.light : ThemeMode.dark));
    }));
  }

  Widget _fontRow() {
    final cur = textScaleNotifier.value;
    return _ctrlRow(CupertinoIcons.textformat_size, 'Font size', 'Tap − / + to make text smaller or larger', _fontStepper(cur));
  }

  // A −  %  + stepper for the app text scale (0.8–1.4 in 0.05 steps).
  Widget _fontStepper(double cur) {
    const step = 0.05, minS = 0.8, maxS = 1.4;
    Widget btn(IconData ic, bool on, VoidCallback onTap) => _Pressable(
          onTap: on ? onTap : null,
          child: Container(
            width: 40, height: 34, alignment: Alignment.center,
            decoration: BoxDecoration(color: on ? _orange.withOpacity(0.10) : _bg, border: Border.all(color: on ? _orange : _cardBorder)),
            child: Icon(ic, size: 18, color: on ? _orange : _grey),
          ),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      btn(CupertinoIcons.minus, cur > minS + 0.001, () => setTextScale(((cur - step).clamp(minS, maxS)).toDouble())),
      Container(width: 54, alignment: Alignment.center, child: Text('${(cur * 100).round()}%', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _navy))),
      btn(CupertinoIcons.plus, cur < maxS - 0.001, () => setTextScale(((cur + step).clamp(minS, maxS)).toDouble())),
    ]);
  }

  // ---- Security -------------------------------------------------------------

  Widget _passwordRow() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _tapRow(
          CupertinoIcons.lock_fill, 'Update password', 'Change your account password',
          () => setState(() {
            _pwOpen = !_pwOpen;
            _pwErr = null;
            _pwSaved = false;
          }),
          trailing: AnimatedRotation(turns: _pwOpen ? 0.5 : 0, duration: const Duration(milliseconds: 200), child: Icon(CupertinoIcons.chevron_down, size: 15, color: _grey)),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _pwOpen
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _pwField('Current password', _cur),
                    const SizedBox(height: 10),
                    _pwField('New password', _new),
                    const SizedBox(height: 10),
                    _pwField('Confirm new password', _conf),
                    if (_pwErr != null) ...[
                      const SizedBox(height: 10),
                      Row(children: [
                        const Icon(CupertinoIcons.exclamationmark_circle_fill, size: 15, color: Color(0xFFD23B3B)),
                        const SizedBox(width: 6),
                        Expanded(child: Text(_pwErr!, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: const Color(0xFFD23B3B)))),
                      ]),
                    ] else if (_pwSaved) ...[
                      const SizedBox(height: 10),
                      Row(children: [
                        const Icon(CupertinoIcons.checkmark_alt_circle_fill, size: 15, color: Color(0xFF1E9E5A)),
                        const SizedBox(width: 6),
                        Expanded(child: Text('Password updated', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: const Color(0xFF1E9E5A)))),
                      ]),
                    ],
                    const SizedBox(height: 12),
                    _Pressable(
                      onTap: _savingPw ? () {} : _savePassword,
                      child: Container(
                        height: 44, alignment: Alignment.center,
                        decoration: BoxDecoration(gradient: _acGrad, borderRadius: BorderRadius.zero, ),
                        child: _savingPw
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                            : Text('Update password', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
                      ),
                    ),
                  ]),
                )
              : const SizedBox(width: double.infinity),
        ),
      ]);

  Widget _pwField(String hint, TextEditingController c) {
    final shown = _shownPw.contains(c);
    return Container(
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(gradient: _cardGradient, borderRadius: BorderRadius.zero, border: Border.all(color: _cardBorder)),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: c,
            obscureText: !shown,
            enableSuggestions: false,
            autocorrect: false,
            style: GoogleFonts.inter(fontSize: 13.5, color: _navy),
            decoration: InputDecoration(border: InputBorder.none, isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 13), hintText: hint, hintStyle: GoogleFonts.inter(fontSize: 13, color: _grey.withOpacity(0.7))),
          ),
        ),
        // Eye toggle — tap to show/hide this field's text.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => shown ? _shownPw.remove(c) : _shownPw.add(c)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Icon(shown ? CupertinoIcons.eye_slash_fill : CupertinoIcons.eye_fill, size: 18, color: shown ? _ac : _grey),
          ),
        ),
      ]),
    );
  }

  Widget _activityRow() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _tapRow(
          CupertinoIcons.device_laptop, 'Active devices & sessions', 'Devices signed in to your account',
          () {
            setState(() => _actOpen = !_actOpen);
            if (_actOpen && _devices == null) _loadDevices();
          },
          trailing: AnimatedRotation(turns: _actOpen ? 0.5 : 0, duration: const Duration(milliseconds: 200), child: Icon(CupertinoIcons.chevron_down, size: 15, color: _grey)),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !_actOpen
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: _devices == null
                      ? const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: CupertinoActivityIndicator()))
                      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          // Count + refresh.
                          Row(children: [
                            Expanded(child: Text(_deviceSummary(), style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w600, color: _grey))),
                            _Pressable(
                              onTap: () { setState(() => _devices = null); _loadDevices(); },
                              child: Padding(padding: const EdgeInsets.all(4), child: Icon(CupertinoIcons.refresh, size: 16, color: _ac)),
                            ),
                          ]),
                          if (_devices!.isEmpty)
                            Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text('No active devices.', style: GoogleFonts.inter(fontSize: 12.5, color: _grey)))
                          else ...[
                            for (final d in _devices!) _deviceTile(d as Map<String, dynamic>),
                            const SizedBox(height: 8),
                            Text('To remove a device, contact your administrator.', style: GoogleFonts.inter(fontSize: 11, color: _grey)),
                          ],
                        ]),
                ),
        ),
      ]);

  Widget _deviceTile(Map<String, dynamic> d) {
    final platform = (d['platform']?.toString() ?? '').trim();
    final model = (d['model']?.toString() ?? '').trim();
    final name = _deviceName(platform, model);
    final isMobile = platform.toLowerCase().contains('android') || platform.toLowerCase().contains('ios');
    final isCurrent = (d['device_id']?.toString() ?? '') == _currentDeviceId && _currentDeviceId != null;
    final added = _StudentHomeState._fmtAt(d['first_seen']?.toString());
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        gradient: _cardGradient,
        borderRadius: BorderRadius.zero,
        border: Border.all(color: isCurrent ? _ac.withOpacity(0.55) : _cardBorder, width: isCurrent ? 1.4 : 1),
      ),
      child: Row(children: [
        Icon(isMobile ? CupertinoIcons.device_phone_portrait : CupertinoIcons.desktopcomputer, size: 18, color: _ac),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: _navy))),
            if (isCurrent) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: _ac.withOpacity(0.14), borderRadius: BorderRadius.zero),
                child: Text('THIS DEVICE', style: GoogleFonts.inter(fontSize: 8, fontWeight: FontWeight.w800, color: _ac, letterSpacing: 0.4)),
              ),
            ],
          ]),
          Text('Last seen ${_StudentHomeState._fmtAt(d['last_seen']?.toString())}${added.isNotEmpty ? ' · added $added' : ''}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 11, color: _grey)),
        ])),
        // View-only — devices are removed by an admin, not the user.
        if (isCurrent) Icon(CupertinoIcons.checkmark_circle_fill, size: 16, color: _ac),
      ]),
    );
  }

}

/// Animated count-up + hover/tappable stat tile (dashboard).
class _StatCard extends StatefulWidget {
  const _StatCard({required this.value, required this.label, this.icon, this.onTap});
  final String value;
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  State<_StatCard> createState() => _StatCardState();
}

class _StatCardState extends State<_StatCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final target = double.tryParse(widget.value);
    final tappable = widget.onTap != null;
    return MouseRegion(
      cursor: tappable ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              // Soft ambient gradient; warms to an orange glow on hover.
              gradient: _hover
                  ? LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_orange.withOpacity(0.22), _orange.withOpacity(0.08)])
                  : _cardGradient,
              borderRadius: BorderRadius.zero,
              border: Border.all(color: _hover ? _orange.withOpacity(0.55) : _cardBorder, width: _hover ? 1.5 : 1),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (widget.icon != null)
                  Container(
                    width: 30, height: 30, alignment: Alignment.center,
                    decoration: BoxDecoration(color: _orange.withOpacity(0.12), borderRadius: BorderRadius.zero),
                    child: Icon(widget.icon, size: 16, color: _orange),
                  ),
                const Spacer(),
                if (tappable) Icon(CupertinoIcons.chevron_right, size: 14, color: _orange.withOpacity(_hover ? 0.9 : 0.35)),
              ]),
              const SizedBox(height: 12),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: target ?? 0),
                duration: const Duration(milliseconds: 1600),
                curve: Curves.easeOutCubic,
                builder: (_, v, __) => Text(
                  target != null ? v.round().toString() : widget.value,
                  style: GoogleFonts.inter(fontSize: 26, fontWeight: FontWeight.w800, color: _orange),
                ),
              ),
              const SizedBox(height: 2),
              Text(widget.label, style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w500, color: _grey)),
            ]),
          ),
        ),
      );
  }
}

/// A notification row that expands on tap to reveal the full text. Themed glass
/// chip with a rotating chevron.
class _StudentHomeNotif extends StatefulWidget {
  const _StudentHomeNotif({required this.text, required this.time, this.read = false, this.body});
  final String text; // heading / title line
  final String time;
  final bool read;
  final String? body; // optional Markdown body (rendered when expanded)

  @override
  State<_StudentHomeNotif> createState() => _StudentHomeNotifState();
}

class _StudentHomeNotifState extends State<_StudentHomeNotif> {
  bool _open = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = _open || _hover;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _open = !_open),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
          // Softer than the stat cards: flat when idle, gentle highlight on
          // hover/expand.
          decoration: BoxDecoration(
            gradient: active
                ? LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_orange.withOpacity(0.16), _orange.withOpacity(0.05)])
                : _cardGradient,
            borderRadius: BorderRadius.zero,
            border: Border.all(color: active ? _orange.withOpacity(0.30) : _cardBorder, width: 1),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 8, height: 8, margin: const EdgeInsets.only(top: 6, right: 12), decoration: BoxDecoration(color: widget.read ? _grey : _orange, shape: BoxShape.circle)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topLeft,
                  child: Builder(builder: (context) {
                    final hasBody = widget.body?.trim().isNotEmpty ?? false;
                    if (!hasBody) {
                      return Text(
                        widget.text,
                        maxLines: _open ? null : 2,
                        overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
                        style: GoogleFonts.inter(fontSize: 13, color: _navy, height: 1.5),
                      );
                    }
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(
                        widget.text,
                        maxLines: _open ? null : 2,
                        overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
                        style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: _navy, height: 1.4),
                      ),
                      const SizedBox(height: 4),
                      // Expanded → rendered Markdown; collapsed → a plain snippet.
                      if (_open)
                        MarkdownView(text: widget.body!, textColor: _navy, mutedColor: _grey, accent: _orange, borderColor: _cardBorder, dark: _isDark)
                      else
                        Text(
                          widget.body!.replaceAll(RegExp(r'\s+'), ' ').trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(fontSize: 12.5, color: _grey, height: 1.4),
                        ),
                    ]);
                  }),
                ),
                const SizedBox(height: 4),
                Text(widget.time, style: GoogleFonts.inter(fontSize: 11, color: _grey)),
              ]),
            ),
            const SizedBox(width: 8),
            AnimatedRotation(
              turns: _open ? 0.5 : 0,
              duration: const Duration(milliseconds: 180),
              child: Icon(CupertinoIcons.chevron_down, size: 16, color: active ? _orange : _grey),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Generic press-scale wrapper.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback? onTap; // null = disabled (no press/hover affordance)

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final scale = !enabled ? 1.0 : (_down ? 0.96 : (_hover ? 1.03 : 1.0));
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque, // whole area tappable, not just the glyphs
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: enabled ? () => setState(() => _down = false) : null,
        onTap: widget.onTap,
        child: AnimatedScale(scale: scale, duration: const Duration(milliseconds: 140), curve: Curves.easeOutCubic, child: widget.child),
      ),
    );
  }
}

/// Collapsible "Day" folder inside a module on the student course view.
/// A course-content list row (a lesson / material) that washes orange, grows a
/// left accent bar, and nudges its content on hover — while keeping the flat
/// bottom-divider list styling. Pointer-only affordance; taps still open it.
class _HoverRow extends StatefulWidget {
  const _HoverRow({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: _hover ? Color.alphaBlend(_orange.withOpacity(0.06), _surface) : Colors.transparent,
            border: Border(
              bottom: BorderSide(color: _line),
              left: BorderSide(color: _hover ? _orange : Colors.transparent, width: 3),
            ),
          ),
          padding: EdgeInsets.only(left: _hover ? 12 : 0, top: 12, bottom: 12),
          child: widget.child,
        ),
      ),
    );
  }
}

class _DayFolder extends StatefulWidget {
  const _DayFolder({required this.label, required this.count, required this.children});
  final String label;
  final int count;
  final List<Widget> children;

  @override
  State<_DayFolder> createState() => _DayFolderState();
}

class _DayFolderState extends State<_DayFolder> {
  bool _open = true;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // Each day is its own bordered box: tinted header (tap to collapse) with a
    // divider under it when open, then its lessons.
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(color: _surface, border: Border.all(color: _cardBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _open = !_open),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _orange.withOpacity(_hover ? 0.15 : 0.08),
              border: _open ? Border(bottom: BorderSide(color: _cardBorder)) : null,
            ),
            child: Row(children: [
              Icon(_open ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_right, size: 12, color: _orange),
              const SizedBox(width: 8),
              Icon(_open ? CupertinoIcons.folder_fill : CupertinoIcons.folder, size: 15, color: _orange),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.label, style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w700, color: _navy))),
              Text('${widget.count} ${widget.count == 1 ? 'item' : 'items'}', style: GoogleFonts.inter(fontSize: 11.5, color: _grey)),
            ]),
          ),
        ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open
              ? Padding(padding: const EdgeInsets.fromLTRB(10, 4, 10, 8), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children))
              : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }
}

/// Personal notes — list + create/edit/delete against /api/v1/me/notes.
class _NotesView extends StatefulWidget {
  const _NotesView({required this.auth});
  final AuthService auth;

  @override
  State<_NotesView> createState() => _NotesViewState();
}

class _NotesViewState extends State<_NotesView> {
  bool _loading = true;
  List<Map<String, dynamic>> _notes = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.auth.apiGet('/api/v1/me/notes');
      _notes = ((ApiClient.decode(r)['notes'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  // Open a full-page, Notion-style editor. Reloads the list on return.
  Future<void> _open({Map<String, dynamic>? note}) async {
    await Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _NotePageEditor(auth: widget.auth, note: note),
    ));
    _load();
  }

  Future<void> _delete(String id) async {
    try {
      await widget.auth.apiDelete('/api/v1/me/notes/$id');
      _load();
    } catch (_) {}
  }

  // Strip markdown markers for the one-line list preview.
  static String _plainPreview(String body) {
    return body
        .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s+', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*[-*]\s+\[[ xX]\]\s*', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*[-*]\s+', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*\d+\.\s+', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*>\s+', multiLine: true), '')
        .replaceAll(RegExp(r'`{1,3}'), '')
        .replaceAll(RegExp(r'\*\*|\*|__|_|~~'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Padding(padding: EdgeInsets.symmetric(vertical: 30), child: Center(child: CupertinoActivityIndicator()));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Pressable(
        onTap: () => _open(),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(gradient: _orangeGrad, borderRadius: BorderRadius.zero),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(CupertinoIcons.add, size: 16, color: Colors.white),
            const SizedBox(width: 6),
            Text('New page', style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white)),
          ]),
        ),
      ),
      const SizedBox(height: 14),
      if (_notes.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Center(child: Text('No pages yet — tap “New page”.', style: GoogleFonts.inter(fontSize: 13, color: _grey))))
      else
        for (var i = 0; i < _notes.length; i++) _noteCard(_notes[i], i),
    ]);
  }

  Widget _noteCard(Map<String, dynamic> n, int index) {
    final title = n['title']?.toString().trim() ?? '';
    final preview = _plainPreview(n['body']?.toString() ?? '');
    return _Entrance(
      index: index,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _open(note: n),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: _surface, border: Border.all(color: _cardBorder)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 1, right: 10), child: Icon(CupertinoIcons.doc_text, size: 17, color: _orange)),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title.isEmpty ? 'Untitled' : title,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: title.isEmpty ? _grey : _navy)),
                if (preview.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 12, color: _grey)),
                ],
              ])),
              const SizedBox(width: 8),
              _Pressable(
                onTap: () => _delete(n['id'].toString()),
                child: const Padding(padding: EdgeInsets.only(left: 4, top: 2), child: Icon(CupertinoIcons.trash, size: 16, color: Color(0xFFBDBDBD))),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Full-page, Notion-style note editor: a big borderless title, a block/format
/// toolbar that inserts Markdown, an Edit⇄Preview toggle (rendered Markdown with
/// tappable to-do checkboxes), and debounced autosave. Markdown is stored in the
/// note's plain `body`, so no backend change is needed.
class _NotePageEditor extends StatefulWidget {
  const _NotePageEditor({required this.auth, this.note});
  final AuthService auth;
  final Map<String, dynamic>? note;

  @override
  State<_NotePageEditor> createState() => _NotePageEditorState();
}

class _NotePageEditorState extends State<_NotePageEditor> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  final FocusNode _bodyFocus = FocusNode();
  Timer? _debounce;
  String? _id;
  bool _preview = false;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _id = widget.note?['id']?.toString();
    _title = TextEditingController(text: widget.note?['title']?.toString() ?? '');
    _body = TextEditingController(text: widget.note?['body']?.toString() ?? '');
    // Open existing notes (with content) in Preview by default; new/empty ones
    // start in Edit so you can write straight away.
    _preview = (widget.note?['body']?.toString() ?? '').trim().isNotEmpty;
    _title.addListener(_onChanged);
    _body.addListener(_onChanged);
  }

  void _onChanged() {
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 900), _save);
    if (mounted) setState(() {}); // refresh the "Edited/Saved" chip
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // Best-effort final save on any exit path (back button / swipe).
    if (_dirty) {
      final t = _title.text.trim();
      final b = _body.text.trim();
      if (t.isNotEmpty || b.isNotEmpty) _persist(t, b);
    }
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  Future<void> _persist(String t, String b) async {
    try {
      if (_id == null) {
        final r = await widget.auth.apiPost('/api/v1/me/notes', {'title': t, 'body': b});
        _id = (ApiClient.decode(r)['id'])?.toString();
      } else {
        await widget.auth.apiPatch('/api/v1/me/notes/$_id', {'title': t, 'body': b});
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    if (!_dirty) return;
    final t = _title.text.trim();
    final b = _body.text.trim();
    if (t.isEmpty && b.isEmpty) return;
    _dirty = false;
    if (mounted) setState(() => _saving = true);
    await _persist(t, b);
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _deleteAndPop() async {
    _dirty = false; // don't re-create on dispose
    if (_id != null) {
      try {
        await widget.auth.apiDelete('/api/v1/me/notes/$_id');
      } catch (_) {}
    }
    if (mounted) Navigator.of(context).pop();
  }

  // ---- Markdown insertion helpers (operate on the body controller) ----------

  void _prefixLine(String prefix) {
    final v = _body.value;
    final text = v.text;
    final base = v.selection.baseOffset;
    final start = base < 0 ? text.length : base;
    final lineStart = text.lastIndexOf('\n', start - 1) + 1; // 0 if none
    final nt = text.replaceRange(lineStart, lineStart, prefix);
    _body.value = TextEditingValue(text: nt, selection: TextSelection.collapsed(offset: (base < 0 ? nt.length : base + prefix.length)));
    _onChanged();
    _bodyFocus.requestFocus();
  }

  void _wrap(String token) {
    final v = _body.value;
    final text = v.text;
    final sel = v.selection;
    if (sel.baseOffset < 0 || sel.start == sel.end) {
      final at = sel.baseOffset < 0 ? text.length : sel.start;
      final nt = text.replaceRange(at, at, '$token$token');
      _body.value = TextEditingValue(text: nt, selection: TextSelection.collapsed(offset: at + token.length));
    } else {
      final selected = text.substring(sel.start, sel.end);
      final nt = text.replaceRange(sel.start, sel.end, '$token$selected$token');
      final s = sel.start + token.length;
      _body.value = TextEditingValue(text: nt, selection: TextSelection(baseOffset: s, extentOffset: s + selected.length));
    }
    _onChanged();
    _bodyFocus.requestFocus();
  }

  void _insertBlock(String block) {
    final v = _body.value;
    final text = v.text;
    final at = v.selection.baseOffset < 0 ? text.length : v.selection.baseOffset;
    final lead = (at > 0 && text[at - 1] != '\n') ? '\n' : '';
    final ins = '$lead$block';
    final nt = text.replaceRange(at, at, ins);
    _body.value = TextEditingValue(text: nt, selection: TextSelection.collapsed(offset: at + ins.length));
    _onChanged();
    _bodyFocus.requestFocus();
  }

  // Toggle a `- [ ]` ⇄ `- [x]` on the given source line (from the preview).
  void _toggleCheckbox(int lineIndex) {
    final lines = _body.text.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length) return;
    final l = lines[lineIndex];
    if (RegExp(r'\[[xX]\]').hasMatch(l)) {
      lines[lineIndex] = l.replaceFirst(RegExp(r'\[[xX]\]'), '[ ]');
    } else if (l.contains('[ ]')) {
      lines[lineIndex] = l.replaceFirst('[ ]', '[x]');
    }
    _body.text = lines.join('\n');
    _dirty = true;
    setState(() {});
    _save();
  }

  @override
  Widget build(BuildContext context) {
    _isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(children: [
          _topBar(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 120),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    // Title.
                    if (_preview)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(_title.text.trim().isEmpty ? 'Untitled' : _title.text.trim(),
                            style: GoogleFonts.inter(fontSize: 30, fontWeight: FontWeight.w800, color: _title.text.trim().isEmpty ? _grey : _navy, height: 1.2)),
                      )
                    else
                      TextField(
                        controller: _title,
                        maxLines: null,
                        textCapitalization: TextCapitalization.sentences,
                        style: GoogleFonts.inter(fontSize: 30, fontWeight: FontWeight.w800, color: _navy, height: 1.2),
                        decoration: InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          hintText: 'Untitled',
                          hintStyle: GoogleFonts.inter(fontSize: 30, fontWeight: FontWeight.w800, color: _grey.withOpacity(0.5), height: 1.2),
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (!_preview) _toolbar(),
                    const SizedBox(height: 14),
                    // Body.
                    if (_preview)
                      _NoteMarkdown(text: _body.text, onToggle: _toggleCheckbox)
                    else
                      TextField(
                        controller: _body,
                        focusNode: _bodyFocus,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        style: GoogleFonts.inter(fontSize: 15.5, color: _navy, height: 1.65),
                        decoration: InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          hintText: 'Start writing. Use the toolbar to add headings, lists, to-dos, quotes and code…',
                          hintStyle: GoogleFonts.inter(fontSize: 15.5, color: _grey.withOpacity(0.7), height: 1.65),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _topBar() {
    final status = _saving ? 'Saving…' : (_dirty ? 'Edited' : 'Saved');
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
      decoration: BoxDecoration(color: _surface, border: Border(bottom: BorderSide(color: _cardBorder))),
      child: Row(children: [
        _Pressable(onTap: () => Navigator.of(context).maybePop(), child: Padding(padding: const EdgeInsets.all(8), child: Icon(CupertinoIcons.chevron_back, size: 22, color: _navy))),
        const SizedBox(width: 2),
        Icon(CupertinoIcons.doc_text, size: 16, color: _grey),
        const SizedBox(width: 6),
        Flexible(child: Text(status, style: GoogleFonts.inter(fontSize: 11.5, color: _grey))),
        const Spacer(),
        _Pressable(
          onTap: () {
            FocusScope.of(context).unfocus();
            setState(() => _preview = !_preview);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(color: _preview ? _orange.withOpacity(0.12) : _surface, border: Border.all(color: _preview ? _orange : _cardBorder)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(_preview ? CupertinoIcons.pencil : CupertinoIcons.eye, size: 14, color: _orange),
              const SizedBox(width: 5),
              Text(_preview ? 'Edit' : 'Preview', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: _orange)),
            ]),
          ),
        ),
        if (_id != null) ...[
          const SizedBox(width: 8),
          _Pressable(onTap: _deleteAndPop, child: const Padding(padding: EdgeInsets.all(6), child: Icon(CupertinoIcons.trash, size: 18, color: Color(0xFFBDBDBD)))),
        ],
      ]),
    );
  }

  Widget _toolbar() {
    Widget btn(String tip, Widget child, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Tooltip(
            message: tip,
            child: _Pressable(
              onTap: onTap,
              child: Container(
                height: 32,
                constraints: const BoxConstraints(minWidth: 34),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(color: _surface, border: Border.all(color: _cardBorder)),
                child: child,
              ),
            ),
          ),
        );
    Widget lbl(String s) => Text(s, style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w800, color: _navy));
    Widget ic(IconData i) => Icon(i, size: 17, color: _navy);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        btn('Heading 1', lbl('H1'), () => _prefixLine('# ')),
        btn('Heading 2', lbl('H2'), () => _prefixLine('## ')),
        btn('Heading 3', lbl('H3'), () => _prefixLine('### ')),
        const SizedBox(width: 4),
        btn('Bold', ic(CupertinoIcons.bold), () => _wrap('**')),
        btn('Italic', ic(CupertinoIcons.italic), () => _wrap('*')),
        btn('Inline code', ic(Icons.code), () => _wrap('`')),
        const SizedBox(width: 4),
        btn('Bulleted list', ic(CupertinoIcons.list_bullet), () => _prefixLine('- ')),
        btn('Numbered list', ic(CupertinoIcons.list_number), () => _prefixLine('1. ')),
        btn('To-do', ic(CupertinoIcons.checkmark_square), () => _prefixLine('- [ ] ')),
        const SizedBox(width: 4),
        btn('Quote', ic(CupertinoIcons.text_quote), () => _prefixLine('> ')),
        btn('Code block', ic(Icons.data_object), () => _insertBlock('```\n\n```\n')),
        btn('Divider', ic(Icons.horizontal_rule), () => _insertBlock('\n---\n')),
      ]),
    );
  }
}

/// Success pop shown after a submit — a checkmark that springs in, then the
/// dialog auto-dismisses.
class _SubmitSuccess extends StatefulWidget {
  const _SubmitSuccess({this.label = 'Submitted!'});
  final String label;
  @override
  State<_SubmitSuccess> createState() => _SubmitSuccessState();
}

class _SubmitSuccessState extends State<_SubmitSuccess> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1300), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    _isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 650),
        curve: Curves.elasticOut,
        builder: (_, t, __) => Transform.scale(
          scale: (0.55 + 0.45 * t).clamp(0.0, 1.25),
          child: Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 26),
              decoration: BoxDecoration(color: _surface, border: Border.all(color: _cardBorder)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 66, height: 66,
                  decoration: const BoxDecoration(color: _green, shape: BoxShape.circle),
                  child: const Icon(CupertinoIcons.checkmark_alt, color: Colors.white, size: 40),
                ),
                const SizedBox(height: 14),
                Text(widget.label, style: GoogleFonts.inter(fontSize: 15.5, fontWeight: FontWeight.w800, color: _navy)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Student-palette wrapper around the shared [MarkdownView].
class _NoteMarkdown extends StatelessWidget {
  const _NoteMarkdown({required this.text, this.onToggle});
  final String text;
  final void Function(int lineIndex)? onToggle;

  @override
  Widget build(BuildContext context) => MarkdownView(
        text: text,
        onToggle: onToggle,
        textColor: _navy,
        mutedColor: _grey,
        accent: _orange,
        borderColor: _cardBorder,
        dark: _isDark,
      );
}

/// Full-page material reader. Shows one material at a time and lets the learner
/// page through ALL the materials in the module with Previous / Next. Text is
/// rendered inline as Markdown; video/link/document materials show an Open
/// button (handled by [onOpen], which opens them the normal way).
class _TextMaterialScreen extends StatefulWidget {
  const _TextMaterialScreen({required this.auth, required this.items, required this.index, required this.onOpen});
  final AuthService auth;
  final List<Map<String, dynamic>> items; // all materials in module order
  final int index;
  final void Function(Map<String, dynamic> material) onOpen;

  @override
  State<_TextMaterialScreen> createState() => _TextMaterialScreenState();
}

class _TextMaterialScreenState extends State<_TextMaterialScreen> {
  late int _i;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _i = widget.index;
    _stamp();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // Record last-access so Resume returns here, and auto-mark the material
  // complete on view (videos complete when watched, not on open).
  void _stamp() {
    final it = widget.items[_i];
    final id = it['id']?.toString();
    if (id == null) return;
    widget.auth.apiPost('/api/v1/me/lessons/$id/progress', {'position': 0}).ignore();
    if ((it['type']?.toString() ?? 'text') != 'video' && it['completed'] != true) {
      it['completed'] = true;
      widget.auth.apiPost('/api/v1/me/lessons/$id/complete', {}).ignore();
    }
  }

  void _go(int delta) {
    final n = _i + delta;
    if (n < 0 || n >= widget.items.length) return;
    setState(() => _i = n);
    _stamp();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _complete() async {
    final it = widget.items[_i];
    try {
      await widget.auth.apiPost('/api/v1/me/lessons/${it['id']}/complete', {});
      if (mounted) setState(() => it['completed'] = true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    _isDark = Theme.of(context).brightness == Brightness.dark;
    final it = widget.items[_i];
    final type = it['type']?.toString() ?? 'text';
    final title = it['title']?.toString() ?? 'Material';
    final body = it['url']?.toString() ?? '';
    final done = it['completed'] == true;
    final isVideo = type == 'video' && body.isNotEmpty;
    final hasPrev = _i > 0;
    final hasNext = _i < widget.items.length - 1;
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(children: [
          // Top bar.
          Container(
            padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
            decoration: BoxDecoration(color: _surface, border: Border(bottom: BorderSide(color: _cardBorder))),
            child: Row(children: [
              _Pressable(onTap: () => Navigator.of(context).maybePop(), child: Padding(padding: const EdgeInsets.all(8), child: Icon(CupertinoIcons.chevron_back, size: 22, color: _navy))),
              const SizedBox(width: 2),
              Icon(CupertinoIcons.doc_text_fill, size: 16, color: _orange),
              const SizedBox(width: 6),
              Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: _navy))),
              if (type == 'text') ...[
                _readerFontBtn(CupertinoIcons.minus, textScaleNotifier.value > 0.801, () => setTextScale(((textScaleNotifier.value - 0.05).clamp(0.8, 1.4)).toDouble())),
                const SizedBox(width: 6),
                _readerFontBtn(CupertinoIcons.plus, textScaleNotifier.value < 1.399, () => setTextScale(((textScaleNotifier.value + 0.05).clamp(0.8, 1.4)).toDouble())),
                const SizedBox(width: 10),
              ],
              Text('${_i + 1} / ${widget.items.length}', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _grey)),
            ]),
          ),
          // Body.
          Expanded(
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
              child: Center(
                child: ConstrainedBox(
                  // Both video and text get a wide frame (text much wider than
                  // the old reading width, per request).
                  constraints: BoxConstraints(maxWidth: isVideo ? 1180 : 1100),
                  // The material sits in a bordered "page" box so the text isn't
                  // floating on the bare background.
                  // Text materials: each main (##) section becomes its own box.
                  child: type == 'text'
                      ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          _sectionBox(Text(title, style: GoogleFonts.inter(fontSize: 26, fontWeight: FontWeight.w800, color: _navy, height: 1.25))),
                          if (body.trim().isEmpty)
                            _sectionBox(Text('No content in this material.', style: GoogleFonts.inter(fontSize: 14, color: _grey)))
                          else
                            for (final s in _splitSections(body)) _sectionBox(_NoteMarkdown(text: s)),
                        ])
                      : Container(
                          width: double.infinity,
                          padding: isVideo ? const EdgeInsets.all(12) : const EdgeInsets.fromLTRB(22, 22, 22, 26),
                          decoration: BoxDecoration(color: _surface, border: Border.all(color: _cardBorder)),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Text(title, style: GoogleFonts.inter(fontSize: 26, fontWeight: FontWeight.w800, color: _navy, height: 1.25)),
                            const SizedBox(height: 16),
                            if (type == 'video' && body.isNotEmpty) _videoPlayer(it, body) else _openCard(type, it),
                          ]),
                        ),
                ),
              ),
            ),
          ),
          // Bottom navigation: Previous / mark done / Next.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: _surface, border: Border(top: BorderSide(color: _cardBorder))),
            child: Row(children: [
              _navButton(CupertinoIcons.chevron_back, 'Previous', hasPrev, () => _go(-1)),
              const Spacer(),
              _Pressable(
                onTap: done ? null : _complete,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(color: done ? _green.withOpacity(0.12) : _orange.withOpacity(0.10), border: Border.all(color: done ? _green : _orange)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(done ? CupertinoIcons.checkmark_alt_circle_fill : CupertinoIcons.circle, size: 16, color: done ? _green : _orange),
                    const SizedBox(width: 6),
                    Text(done ? 'Completed' : 'Mark done', style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w700, color: done ? _green : _orange)),
                  ]),
                ),
              ),
              const Spacer(),
              _navButton(CupertinoIcons.chevron_forward, 'Next', hasNext, () => _go(1), trailing: true),
            ]),
          ),
        ]),
      ),
    );
  }

  // A video material — plays inline in the reader (no separate tab/route).
  Widget _videoPlayer(Map<String, dynamic> it, String url) {
    final id = it['id'].toString();
    final startAt = ((it['position'] ?? 0) as num).toInt();
    return VideoPlayerScreen(
      key: ValueKey('vid-$id'), // fresh player when paging to another video
      embedded: true,
      autoPlay: false, // wait for the student to press play (no autoplay)
      url: url,
      watermark: widget.auth.user?.email ?? 'student',
      title: it['title']?.toString() ?? 'Video',
      authToken: widget.auth.token,
      startAt: Duration(seconds: startAt),
      onProgress: (pos, dur) => widget.auth.apiPost('/api/v1/me/lessons/$id/progress', {'position': pos.inSeconds}).ignore(),
      onCompleted: () {
        widget.auth.apiPost('/api/v1/me/lessons/$id/complete', {}).ignore();
        if (mounted) setState(() => it['completed'] = true);
      },
    );
  }

  // A non-text material (link / document): show what it is and an Open button
  // that opens it the usual way (new tab / viewer).
  Widget _openCard(String type, Map<String, dynamic> it) {
    final (IconData icon, String label, String action) = switch (type) {
      'video' => (CupertinoIcons.play_rectangle_fill, 'This is a video material.', 'Play video'),
      'file' => (CupertinoIcons.doc_richtext, 'This is a document material.', 'Open document'),
      _ => (CupertinoIcons.link, 'This is a link material.', 'Open link'),
    };
    return Column(children: [
      const SizedBox(height: 8),
      Icon(icon, size: 46, color: _orange),
      const SizedBox(height: 12),
      Text(label, textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 14, color: _grey)),
      const SizedBox(height: 16),
      _Pressable(
        onTap: () => widget.onOpen(it),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: const BoxDecoration(gradient: _orangeGrad),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(CupertinoIcons.arrow_up_right_square, size: 16, color: Colors.white),
            const SizedBox(width: 8),
            Text(action, style: GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white)),
          ]),
        ),
      ),
      const SizedBox(height: 8),
    ]);
  }

  // A bordered "card" for one section of a text material.
  Widget _sectionBox(Widget child) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
        decoration: BoxDecoration(color: _surface, border: Border.all(color: _cardBorder)),
        child: child,
      );

  // Split a material's Markdown at each main "## " heading — content before the
  // first heading is its own section — so each section renders in its own box.
  List<String> _splitSections(String md) {
    final sections = <String>[];
    final buf = <String>[];
    for (final line in md.split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('## ') && !t.startsWith('### ') && buf.isNotEmpty) {
        final chunk = buf.join('\n').trim();
        if (chunk.isNotEmpty) sections.add(chunk);
        buf.clear();
      }
      buf.add(line);
    }
    final last = buf.join('\n').trim();
    if (last.isNotEmpty) sections.add(last);
    return sections.isEmpty ? [md.trim()] : sections;
  }

  // Small − / + button in the reader header to resize the reading text.
  Widget _readerFontBtn(IconData ic, bool on, VoidCallback onTap) => _Pressable(
        onTap: on ? onTap : null,
        child: Container(
          width: 30, height: 28, alignment: Alignment.center,
          decoration: BoxDecoration(color: on ? _orange.withOpacity(0.10) : _bg, border: Border.all(color: on ? _orange : _cardBorder)),
          child: Icon(ic, size: 15, color: on ? _orange : _grey),
        ),
      );

  Widget _navButton(IconData icon, String label, bool enabled, VoidCallback onTap, {bool trailing = false}) {
    final color = enabled ? Colors.white : _grey;
    final bg = enabled ? _orange : (_isDark ? Colors.white.withOpacity(0.06) : const Color(0xFFECECEF));
    final row = Row(mainAxisSize: MainAxisSize.min, children: [
      if (!trailing) Icon(icon, size: 16, color: color),
      if (!trailing) const SizedBox(width: 5),
      Text(label, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
      if (trailing) const SizedBox(width: 5),
      if (trailing) Icon(icon, size: 16, color: color),
    ]);
    return _Pressable(
      onTap: enabled ? onTap : null,
      child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: BoxDecoration(color: bg), child: row),
    );
  }
}
