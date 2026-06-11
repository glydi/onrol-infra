import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme_controller.dart';
import 'login_screen.dart';
import 'video_player_screen.dart';

// Palette — red-orange accent.
const _orange = Color(0xFFFF4F2B);
const _green = Color(0xFF2D8A4E);
const _greenBg = Color(0xFFEAFAF0);

// Brightness-aware palette. `_isDark` is set at the start of each build / dialog.
bool _isDark = false;
Color get _navy => _isDark ? const Color(0xFFECEDF2) : const Color(0xFF1A1A2E);
Color get _grey => _isDark ? const Color(0xFF9AA0AC) : const Color(0xFF888888);
Color get _peach => _isDark ? const Color(0xFF2C231C) : const Color(0xFFFFF3EC);
Color get _peachSoft => _isDark ? const Color(0xFF241D17) : const Color(0xFFFFF8F5);
Color get _bg => _isDark ? const Color(0xFF0E0F14) : const Color(0xFFFFF6F1);
Color get _surface => _isDark ? const Color(0xFF1E2027) : Colors.white;
Color get _line => _isDark ? const Color(0xFF2C2F37) : const Color(0xFFF0F0F0);

// ---- Glassmorphism --------------------------------------------------------
// Frosted translucent fill + hairline highlight border + soft drop shadow.
Color get _glassFill => _isDark ? Colors.white.withOpacity(0.07) : Colors.white.withOpacity(0.55);
Color get _glassBorder => _isDark ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.65);
// Opaque card surface for elements inside popups (white in light mode) so text
// is crisp and clearly visible on top of the frosted panel.
Color get _cardFill => _isDark ? const Color(0xFF262932) : Colors.white;
Color get _cardBorder => _isDark ? Colors.white.withOpacity(0.07) : const Color(0xFFF0ECE9);

/// Wraps [child] in a frosted-glass surface (backdrop blur + translucent fill).
/// Use sparingly — each one is a real BackdropFilter.
Widget _glass({
  required Widget child,
  double radius = 22,
  EdgeInsetsGeometry? padding,
  double blur = 18,
  Color? tint,
}) {
  final r = BorderRadius.circular(radius);
  return ClipRRect(
    borderRadius: r,
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: tint ?? _glassFill,
          borderRadius: r,
          border: Border.all(color: _glassBorder, width: 1),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(_isDark ? 0.30 : 0.07), blurRadius: 30, offset: const Offset(0, 14))],
        ),
        child: child,
      ),
    ),
  );
}

/// Full-bleed backdrop: a base gradient plus a few large, heavily-blurred
/// colour blobs so the glass panels have something rich to refract.
class _GlassBackdrop extends StatelessWidget {
  const _GlassBackdrop();

  @override
  Widget build(BuildContext context) {
    final blob = ui.ImageFilter.blur(sigmaX: 90, sigmaY: 90);
    Widget circle(Color c, double d) => ImageFiltered(
          imageFilter: blob,
          child: Container(width: d, height: d, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _isDark
              ? const [Color(0xFF0E0F14), Color(0xFF14161F)]
              : const [Color(0xFFFFF1EA), Color(0xFFFDEAF6)],
        ),
      ),
      child: Stack(children: [
        Positioned(top: -120, left: -100, child: circle(_orange.withOpacity(_isDark ? 0.22 : 0.30), 380)),
        Positioned(top: 80, right: -140, child: circle(const Color(0xFFFF7A4D).withOpacity(_isDark ? 0.18 : 0.28), 420)),
        Positioned(bottom: -160, left: 120, child: circle(const Color(0xFF7C5CFF).withOpacity(_isDark ? 0.16 : 0.18), 460)),
      ]),
    );
  }
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
    _Tile(CupertinoIcons.chart_bar_fill, 'Progress', 'progress'),
    _Tile(CupertinoIcons.doc_text_fill, 'Assignments', 'assignments'),
    _Tile(CupertinoIcons.videocam_fill, 'Live Classes', 'live'),
    _Tile(CupertinoIcons.rosette, 'Certificates', 'certificates'),
    _Tile(CupertinoIcons.list_number, 'Leaderboard', 'leaderboard'),
    _Tile(CupertinoIcons.play_circle_fill, 'Resume', 'resume'),
    _Tile(CupertinoIcons.gear_alt_fill, 'Settings', 'settings'),
    _Tile(CupertinoIcons.square_arrow_right, 'Log Out', 'logout'),
  ];

  String get _name => widget.auth.user?.fullName ?? 'Student';
  String get _firstName => _name.split(RegExp(r'[\s@]')).first;

  // Day streak shown in the profile card (placeholder until a backend streak
  // exists). Tapping the chip opens the Achievements panel.
  final int _streak = 7;

  // Which of the three dashboard sections is focused: 0 = menu (matrix),
  // 1 = profile, 2 = live news. Drives the focus highlight.
  int _focused = 0;

  // XP earned grows with progress: 10 XP per completed lesson.
  static int _xpFromCourses(List courses) => courses.fold<int>(
      0, (sum, c) => sum + (((c as Map)['lessons_done'] ?? 0) as num).toInt() * 10);

  @override
  void initState() {
    super.initState();
    _loadAvatarFromServer();
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
        child: Text(t, textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 13, color: _grey)),
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

  @override
  Widget build(BuildContext context) {
    _isDark = Theme.of(context).brightness == Brightness.dark;
    // Two-column dashboard: the checkerboard + branding on the left, a profile
    // card and the live AI-news feed on the right. Stacks to one column when the
    // viewport is too narrow for the side panel (phones / small windows).
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          // Soft, colourful backdrop the frosted-glass panels refract.
          const Positioned.fill(child: _GlassBackdrop()),
          SafeArea(
            child: LayoutBuilder(builder: (context, cns) {
              return cns.maxWidth >= 1000 ? _wideLayout() : _narrowLayout();
            }),
          ),
        ],
      ),
    );
  }

  // Desktop / wide: matrix centered (no scroll) on the left, sidebar pinned
  // right. Only the sidebar (profile + AI news) scrolls.
  // Wraps a dashboard section in a focus ring. The focused section (set on
  // hover) gets a themed accent border + glow; the others stay neutral.
  Widget _focusable(int index, {required Widget child, double radius = 26}) {
    final on = _focused == index;
    return MouseRegion(
      onEnter: (_) {
        if (_focused != index) setState(() => _focused = index);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: on ? _orange.withOpacity(0.85) : Colors.transparent, width: 2),
          boxShadow: on ? [BoxShadow(color: _orange.withOpacity(0.30), blurRadius: 26, spreadRadius: 1)] : const [],
        ),
        child: child,
      ),
    );
  }

  Widget _wideLayout() => Padding(
        padding: const EdgeInsets.fromLTRB(40, 24, 36, 24),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Center(
              child: LayoutBuilder(builder: (context, c) {
                final side = (c.maxWidth < c.maxHeight ? c.maxWidth : c.maxHeight).clamp(280.0, 620.0).toDouble();
                // No focus ring / boundary on the options — hovering just clears
                // the highlight on the other sections.
                return MouseRegion(
                  onEnter: (_) {
                    if (_focused != 0) setState(() => _focused = 0);
                  },
                  child: _matrix(side),
                );
              }),
            ),
          ),
          const SizedBox(width: 28),
          SizedBox(
            width: 440,
            // Profile card stays pinned; only the AI-news list inside scrolls.
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _focusable(1, child: _profileCard()),
              const SizedBox(height: 12),
              Expanded(child: _focusable(2, child: _AiNewsCard(auth: widget.auth, scrollable: true))),
            ]),
          ),
        ]),
      );

  // Phone / narrow: a single scrolling column.
  Widget _narrowLayout() => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
        child: Column(children: [
          _topBar(),
          const SizedBox(height: 14),
          _focusable(1, child: _profileCard()),
          const SizedBox(height: 14),
          LayoutBuilder(builder: (context, c) {
            return MouseRegion(
              onEnter: (_) {
                if (_focused != 0) setState(() => _focused = 0);
              },
              child: _matrix(c.maxWidth.clamp(260.0, 460.0).toDouble()),
            );
          }),
          const SizedBox(height: 18),
          _focusable(2, child: _AiNewsCard(auth: widget.auth, scrollable: false)),
        ]),
      );

  // ---- Top bar -------------------------------------------------------------

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Brand on the left.
          Text('ONROL', style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w800, color: _orange, letterSpacing: 1)),
          const Spacer(),
          Row(mainAxisSize: MainAxisSize.min, children: [
            // Notification bell — opens announcements/notifications.
            _Pressable(
              onTap: () => _openPanel('notifications'),
              child: Container(
                width: 40, height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: _orange.withOpacity(0.12), shape: BoxShape.circle),
                child: Icon(CupertinoIcons.bell_fill, size: 19, color: _orange),
              ),
            ),
            const SizedBox(width: 12),
            // Streak — fire, themed red-orange.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [_orange, Color(0xFFFF7A4D)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: _orange.withOpacity(0.4), blurRadius: 10, offset: const Offset(0, 4))],
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(CupertinoIcons.flame_fill, color: Colors.white, size: 16),
                const SizedBox(width: 4),
                Text('$_streak', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
              ]),
            ),
            const SizedBox(width: 12),
            // Profile + settings — top-right corner. Opens the full profile section.
            _Pressable(
              onTap: () => _openPanel('profile'),
              child: ValueListenableBuilder<String>(
                valueListenable: avatarNotifier,
                builder: (ctx, av, _) => _avatarBox(av, 40, _firstName.isNotEmpty ? _firstName[0].toUpperCase() : 'S'),
              ),
            ),
          ]),
        ],
      ),
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
                  child: _GridCell(tile: tile, size: cell, onTap: (c) => _openPanel(tile.panel, origin: c)),
                ),
        ));
      }
      rows.add(Row(mainAxisSize: MainAxisSize.min, children: cells));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  // ---- Profile card (right sidebar, top) -----------------------------------

  Widget _profileCard() {
    final initials = _firstName.isNotEmpty ? _firstName[0].toUpperCase() : 'S';
    // Tapping the card opens Profile & settings; tapping the avatar (inner
    // GestureDetector) still opens the picture picker.
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _openPanel('profile'),
        child: _glass(
      padding: const EdgeInsets.all(22),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(
          onTap: _pickAvatar,
          child: ValueListenableBuilder<String>(
            valueListenable: avatarNotifier,
            builder: (ctx, av, _) => _avatarBox(av, 88, initials, editable: true),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            RichText(
              text: TextSpan(children: [
                TextSpan(text: 'Hi, ', style: GoogleFonts.poppins(fontSize: 25, fontWeight: FontWeight.w800, color: _navy)),
                TextSpan(text: _firstName, style: GoogleFonts.poppins(fontSize: 25, fontWeight: FontWeight.w800, color: _orange)),
              ]),
            ),
            const SizedBox(height: 3),
            Text(_roleLabel, style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: _grey)),
            const SizedBox(height: 10),
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(color: _orange.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                child: Text('ONROL Learner', style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w700, color: _orange)),
              ),
              const SizedBox(width: 8),
              _streakChip(),
            ]),
          ]),
        ),
        // Settings affordance — the whole card opens Profile & settings.
        Icon(CupertinoIcons.gear_alt_fill, size: 18, color: _orange.withOpacity(0.55)),
      ]),
    ),
      ),
    );
  }

  // Themed day-streak chip (fire + count). Tap opens the Achievements panel.
  Widget _streakChip() => GestureDetector(
        onTap: () => _openPanel('achievements'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [_orange, Color(0xFFFF7A4D)], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: _orange.withOpacity(0.4), blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(CupertinoIcons.flame_fill, color: Colors.white, size: 14),
            const SizedBox(width: 4),
            Text('$_streak day streak', style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
          ]),
        ),
      );

  // A square (rounded) profile picture. [avatar] is '' / 'p:N' (preset) or a
  // 'data:' URI (uploaded photo). Shows a camera badge when [editable].
  Widget _avatarBox(String avatar, double size, String initials, {bool editable = false}) {
    final radius = size * 0.26;
    final bytes = avatar.startsWith('data:') ? _decodeDataUri(avatar) : null;
    Widget face;
    if (bytes != null) {
      face = Container(
        width: size, height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Colors.white, width: 3),
          image: DecorationImage(image: MemoryImage(bytes), fit: BoxFit.cover),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.22), blurRadius: 14, offset: const Offset(0, 6))],
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
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [BoxShadow(color: a.colors.last.withOpacity(0.35), blurRadius: 14, offset: const Offset(0, 6))],
        ),
        child: a.emoji.isEmpty
            ? Text(initials, style: GoogleFonts.poppins(fontSize: size * 0.40, fontWeight: FontWeight.w800, color: Colors.white))
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
            decoration: BoxDecoration(color: _orange, shape: BoxShape.circle, border: Border.all(color: _surface, width: 2)),
            child: const Icon(CupertinoIcons.camera_fill, size: 12, color: Colors.white),
          ),
        ),
    ]);
  }

  Uint8List? _decodeDataUri(String d) {
    try {
      return base64Decode(d.substring(d.indexOf(',') + 1));
    } catch (_) {
      return null;
    }
  }

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
                Text('Choose a picture', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700, color: _navy)),
                const SizedBox(height: 3),
                Text('Pick a default or upload your own', style: GoogleFonts.poppins(fontSize: 13, color: _grey)),
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
                              borderRadius: BorderRadius.circular(20),
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
                            borderRadius: BorderRadius.circular(16),
                            color: _orange.withOpacity(0.10),
                            border: Border.all(color: _orange.withOpacity(0.5), width: 1.5),
                          ),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(CupertinoIcons.cloud_upload_fill, size: 22, color: _orange),
                            const SizedBox(height: 2),
                            Text('Upload', style: GoogleFonts.poppins(fontSize: 9, fontWeight: FontWeight.w700, color: _orange)),
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
                      child: Text('Close', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w700, color: _orange)),
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
    final d = _panel(key);
    _showPanel(d.$1, d.$2, d.$3, d.$4, heroTag: 'panel-$key', compact: key == 'logout');
  }

  // Course content viewer — modules & lessons from /me/courses/:id/content.
  void _openContent(String courseId, String title) {
    _showPanel(CupertinoIcons.book_fill, title, 'Course content', [
      _future(_apiMap('/api/v1/me/courses/$courseId/content'), (m) {
        final modules = (m['modules'] as List?) ?? [];
        if (modules.isEmpty) return _emptyText('No content in this course yet.');
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: modules.expand<Widget>((mod) {
          final md = mod as Map<String, dynamic>;
          final lessons = (md['lessons'] as List?) ?? [];
          return [
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Text(md['title']?.toString() ?? 'Module', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700, color: _orange)),
            ),
            if (lessons.isEmpty) _emptyText('No lessons.') else ...lessons.map((l) => _lessonRow(l as Map<String, dynamic>)),
            Align(
              alignment: Alignment.centerLeft,
              child: _Pressable(
                onTap: () => _openComments(md['id'].toString(), md['title']?.toString() ?? 'Module'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(CupertinoIcons.chat_bubble_2_fill, size: 15, color: _orange),
                    const SizedBox(width: 6),
                    Text('Comments & Doubts', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: _orange)),
                  ]),
                ),
              ),
            ),
          ];
        }).toList());
      }),
    ]);
  }

  // Comments & doubts thread for a module: list + post (with a "doubt" toggle).
  void _openComments(String moduleId, String moduleTitle) {
    final text = TextEditingController();
    bool doubt = false;
    _showPanel(CupertinoIcons.chat_bubble_2_fill, moduleTitle, 'Comments & Doubts', [
      StatefulBuilder(builder: (ctx, setS) {
        Future<void> post() async {
          if (text.text.trim().isEmpty) return;
          try {
            await widget.auth.apiPost('/api/v1/modules/$moduleId/comments', {'body': text.text.trim(), 'is_doubt': doubt});
            text.clear();
            setS(() {});
          } catch (_) {}
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _future(_apiList('/api/v1/modules/$moduleId/comments', 'comments'), (List items) {
            if (items.isEmpty) return _emptyText('No comments yet. Start the discussion or ask a doubt.');
            return Column(children: items.map((e) {
              final m = e as Map<String, dynamic>;
              final staff = m['staff'] == true;
              final isDoubt = m['is_doubt'] == true;
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: _line)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(m['author']?.toString() ?? 'Someone', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700, color: _navy)),
                    const SizedBox(width: 6),
                    if (staff) Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: _orange.withOpacity(0.14), borderRadius: BorderRadius.circular(4)), child: Text('Mentor', style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w700, color: _orange))),
                    if (isDoubt) Container(margin: const EdgeInsets.only(left: 6), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: const Color(0xFF2D7DF6).withOpacity(0.14), borderRadius: BorderRadius.circular(4)), child: Text('Doubt', style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w700, color: const Color(0xFF2D7DF6)))),
                  ]),
                  const SizedBox(height: 4),
                  Text(m['body']?.toString() ?? '', style: GoogleFonts.poppins(fontSize: 14, color: _navy, height: 1.4)),
                ]),
              );
            }).toList());
          }),
          const SizedBox(height: 12),
          CupertinoTextField(controller: text, placeholder: 'Write a comment…', minLines: 1, maxLines: 4, padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: _line))),
          const SizedBox(height: 8),
          Row(children: [
            _Pressable(onTap: () => setS(() => doubt = !doubt), child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(doubt ? CupertinoIcons.checkmark_square_fill : CupertinoIcons.square, size: 18, color: doubt ? _orange : _grey),
              const SizedBox(width: 6),
              Text('Mark as doubt', style: GoogleFonts.poppins(fontSize: 13, color: _navy)),
            ])),
            const Spacer(),
            _Pressable(onTap: post, child: Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10), decoration: BoxDecoration(color: _orange, borderRadius: BorderRadius.circular(8)),
                child: Text('Post', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)))),
          ]),
        ]);
      }),
    ]);
  }

  Future<void> _enrollCourse(String id, String title, bool self) async {
    try {
      await widget.auth.apiPost('/api/v1/me/courses/$id/enroll', {});
      if (mounted) {
        _showRequestSent(
          self ? 'Enrolled!' : 'Request sent',
          self ? "You're now enrolled in $title." : "Your request for $title was sent — you'll be notified when it's approved.",
          self ? CupertinoIcons.checkmark_alt_circle_fill : CupertinoIcons.paperplane_fill,
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not enroll'), behavior: SnackBarBehavior.floating));
      }
    }
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
                Text(title, textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700, color: _navy)),
                const SizedBox(height: 6),
                Text(sub, textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 13, color: _grey, height: 1.4)),
              ]),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _lessonRow(Map<String, dynamic> l) {
    final type = l['type']?.toString() ?? 'text';
    final done = l['completed'] == true;
    final icon = switch (type) {
      'video' => CupertinoIcons.play_rectangle_fill,
      'link' => CupertinoIcons.link,
      'scorm' || 'xapi' => CupertinoIcons.cube_box_fill,
      _ => CupertinoIcons.doc_text_fill,
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openLesson(l),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _line))),
        child: Row(children: [
          Icon(icon, size: 20, color: _orange),
          const SizedBox(width: 12),
          Expanded(child: Text(l['title']?.toString() ?? 'Lesson', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: _navy))),
          Icon(done ? CupertinoIcons.checkmark_alt_circle_fill : CupertinoIcons.chevron_right, size: done ? 20 : 16, color: done ? _green : _grey),
        ]),
      ),
    );
  }

  Future<void> _openLesson(Map<String, dynamic> l) async {
    final url = l['url']?.toString() ?? '';
    final type = l['type']?.toString() ?? 'text';
    if (type == 'video' && url.isNotEmpty) {
      // Stream in-app (mp4 native, .m3u8 via hls.js) — not a download.
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          url: url,
          watermark: widget.auth.user?.email ?? 'student',
          title: l['title']?.toString() ?? 'Video',
        ),
      ));
    } else if ((type == 'link' || type == 'file') && url.startsWith('http')) {
      // Open the link / document (PDF, Word, …) — browser renders or downloads it.
      try {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
      } catch (_) {}
    } else if (url.isNotEmpty) {
      // Text lesson: show the body.
      _showPanel(CupertinoIcons.doc_text_fill, l['title']?.toString() ?? 'Lesson', 'Lesson', [
        Text(url, style: GoogleFonts.poppins(fontSize: 14, color: _navy, height: 1.6)),
      ]);
    }
    // Mark complete (best-effort).
    try {
      await widget.auth.apiPost('/api/v1/me/lessons/${l['id']}/complete', {});
    } catch (_) {}
  }

  // Opens a quiz: loads its questions, collects answers, and submits them.
  Future<void> _openAssessment(Map<String, dynamic> a) async {
    final id = a['id'].toString();
    final answers = <String, String>{};
    _showPanel(CupertinoIcons.question_square_fill, a['title']?.toString() ?? 'Quiz',
        a['course']?.toString() ?? 'Quiz', [
      _future(_apiMap('/api/v1/me/assessments/$id'), (m) {
        final qs = (m['questions'] as List?) ?? [];
        if (qs.isEmpty) return _emptyText('This quiz has no questions yet.');
        return StatefulBuilder(builder: (ctx, setS) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
                      style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600, color: _navy)),
                  const SizedBox(height: 8),
                  if (opts.isNotEmpty)
                    ...opts.map((o) => _Pressable(
                          onTap: () => setS(() => answers[qid] = o),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: answers[qid] == o ? _orange.withOpacity(0.12) : _bg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: answers[qid] == o ? _orange : _line),
                            ),
                            child: Row(children: [
                              Icon(answers[qid] == o ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                                  size: 18, color: answers[qid] == o ? _orange : _grey),
                              const SizedBox(width: 10),
                              Expanded(child: Text(o, style: GoogleFonts.poppins(fontSize: 14, color: _navy))),
                            ]),
                          ),
                        ))
                  else
                    CupertinoTextField(
                      placeholder: 'Your answer',
                      onChanged: (v) => answers[qid] = v,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(8), border: Border.all(color: _line)),
                    ),
                ]),
              );
            }),
            const SizedBox(height: 8),
            _Pressable(
              onTap: () async {
                try {
                  await widget.auth.apiPost('/api/v1/me/assessments/$id/submit', {'answers': answers});
                  if (!mounted) return;
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Submitted ✓')));
                } catch (_) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't submit — try again.")));
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: _orange, borderRadius: BorderRadius.circular(10)),
                child: Text('Submit', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            ),
          ]);
        });
      }),
    ]);
  }

  void _showPanel(IconData icon, String title, String sub, List<Widget> body, {Offset? origin, String? heroTag, bool compact = false}) {
    // iOS-style shared-element expansion: push a transparent route so the
    // dashboard stays visible (blurred) behind, and let a Hero morph the tapped
    // tile into the card. See [_PanelRoute] / [_HeroPanelModal].
    Navigator.of(context).push(_PanelRoute(
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
              _apiList('/api/v1/me/announcements', 'announcements'),
              _apiList('/api/v1/me/notifications', 'notifications'),
            ]),
            (List d) {
              final t = d[0] as Map<String, dynamic>;
              final courses = d[1] as List;
              // Merge personal notifications + announcements, newest first.
              final notes = [...(d[3] as List), ...(d[2] as List)]
                ..sort((a, b) => ((b as Map)['at']?.toString() ?? '').compareTo((a as Map)['at']?.toString() ?? ''));
              final totalL = courses.fold<int>(0, (s, c) => s + (((c as Map)['lessons_total'] ?? 0) as num).toInt());
              final doneL = courses.fold<int>(0, (s, c) => s + (((c as Map)['lessons_done'] ?? 0) as num).toInt());
              final overall = totalL > 0 ? doneL / totalL : 0.0;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // Warm greeting.
                Text('Hi, $_firstName 👋', style: GoogleFonts.poppins(fontSize: 19, fontWeight: FontWeight.w700, color: _navy)),
                const SizedBox(height: 2),
                Text("Here's your learning snapshot", style: GoogleFonts.poppins(fontSize: 13, color: _grey)),
                const SizedBox(height: 16),
                // Overall-progress hero with an animated ring.
                if (courses.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _cardFill,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _cardBorder),
                      boxShadow: [BoxShadow(color: _orange.withOpacity(0.07), blurRadius: 16, offset: const Offset(0, 8))],
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
                          Text('${(overall * 100).round()}%', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w800, color: _orange)),
                        ]),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Overall progress', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700, color: _navy)),
                          const SizedBox(height: 3),
                          Text(doneL > 0 ? '$doneL of $totalL lessons complete — keep going!' : 'Start a lesson to build your streak', style: GoogleFonts.poppins(fontSize: 12.5, color: _grey, height: 1.4)),
                        ]),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 16),
                ],
                Row(children: [
                  Expanded(child: _statCard('${t['enrolled'] ?? 0}', 'Enrolled', icon: CupertinoIcons.book_fill, onTap: () => _openPanel('courses'))),
                  const SizedBox(width: 14),
                  Expanded(child: _statCard('${t['completed'] ?? 0}', 'Completed', icon: CupertinoIcons.checkmark_seal_fill, onTap: () => _openPanel('progress'))),
                ]),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: _statCard('${_xpFromCourses(courses)}', 'XP earned', icon: CupertinoIcons.bolt_fill, onTap: () => _openPanel('achievements'))),
                  const SizedBox(width: 14),
                  Expanded(child: _statCard('${t['certificates'] ?? 0}', 'Certificates', icon: CupertinoIcons.rosette, onTap: () => _openPanel('certificates'))),
                ]),
                // Notifications — recent announcements.
                if (notes.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  Row(children: [
                    Icon(CupertinoIcons.bell_fill, size: 16, color: _orange),
                    const SizedBox(width: 6),
                    Text('Notifications', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700, color: _navy)),
                  ]),
                  const SizedBox(height: 8),
                  ...notes.take(3).map((e) {
                    final m = e as Map<String, dynamic>;
                    final course = m['course']?.toString() ?? '';
                    final body = m['body']?.toString() ?? '';
                    final text = [if (course.isNotEmpty) '[$course]', m['title'] ?? '', if (body.isNotEmpty) '— $body'].join(' ');
                    return _notif(text, _fmtAt(m['at']?.toString()));
                  }),
                ],
                const SizedBox(height: 22),
                if (courses.isEmpty)
                  _emptyText('No courses yet — browse the catalog to enroll.')
                else ...[
                  Row(children: [
                    Icon(CupertinoIcons.book_fill, size: 16, color: _orange),
                    const SizedBox(width: 6),
                    Text('Your Courses', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700, color: _navy)),
                  ]),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: _cardFill,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _cardBorder),
                      boxShadow: [BoxShadow(color: _orange.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 5))],
                    ),
                    child: Column(children: courses.map((c) {
                      final m = c as Map<String, dynamic>;
                      return _progress(m['title']?.toString() ?? 'Course', ((m['percent'] ?? 0) as num) / 100);
                    }).toList()),
                  ),
                ],
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
              // Mark personal notifications read (best-effort) once viewed.
              widget.auth.apiPost('/api/v1/me/notifications/read', {}).ignore();
              final entries = <Map<String, dynamic>>[];
              for (final n in (d[0] as List)) {
                final m = n as Map<String, dynamic>;
                final body = m['body']?.toString() ?? '';
                entries.add({'text': [m['title'] ?? '', if (body.isNotEmpty) '— $body'].join(' '), 'at': m['at'], 'read': m['read'] == true});
              }
              for (final a in (d[1] as List)) {
                final m = a as Map<String, dynamic>;
                final body = m['body']?.toString() ?? '';
                final course = m['course']?.toString() ?? '';
                entries.add({'text': [if (course.isNotEmpty) '[$course]', m['title'] ?? '', if (body.isNotEmpty) '— $body'].join(' '), 'at': m['at'], 'read': true});
              }
              entries.sort((a, b) => (b['at']?.toString() ?? '').compareTo(a['at']?.toString() ?? ''));
              if (entries.isEmpty) return _emptyText('No notifications yet.');
              return Column(children: entries.map((e) => _notif(e['text'] as String, _fmtAt(e['at']?.toString()), read: e['read'] == true)).toList());
            },
          ),
        ]);
      case 'resume':
        return (CupertinoIcons.play_circle_fill, 'Resume Learning', 'Pick up where you left off', [
          _future(_apiMap('/api/v1/me/resume'), (m) {
            final r = m['resume'];
            if (r == null) return _emptyText("You're all caught up — nothing to resume.");
            final res = r as Map<String, dynamic>;
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: _line)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(res['course']?.toString() ?? '', style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600, color: _orange)),
                const SizedBox(height: 4),
                Text(res['title']?.toString() ?? 'Next lesson', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700, color: _navy)),
                if ((res['module']?.toString() ?? '').isNotEmpty) Text(res['module'].toString(), style: GoogleFonts.poppins(fontSize: 13, color: _grey)),
                const SizedBox(height: 14),
                _Pressable(
                  onTap: () {
                    Navigator.of(context).maybePop();
                    _openLesson({'id': res['lesson_id'], 'title': res['title'], 'type': res['type'], 'url': res['url']});
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14), alignment: Alignment.center,
                    decoration: BoxDecoration(color: _orange, borderRadius: BorderRadius.circular(10)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(CupertinoIcons.play_fill, color: Colors.white, size: 16),
                      const SizedBox(width: 8),
                      Text('Continue', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                    ]),
                  ),
                ),
              ]),
            );
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
                      onOpen: () => _openContent(m['id'].toString(), m['title']?.toString() ?? 'Course'),
                    ),
                  );
                }),
            ]);
          }),
        ]);
      case 'profile':
        return (CupertinoIcons.person_fill, 'My Profile', 'Manage your details & settings', [
          _ProfilePanel(auth: widget.auth),
          const SizedBox(height: 22),
          Text('Settings', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w700, color: _navy)),
          const SizedBox(height: 8),
          _SettingRow('Push Notifications', 'Get alerts for classes & assignments', true),
          _SettingRow('Email Digest', 'Weekly progress summary', true),
          const _DarkModeRow(),
          _SettingRow('Study Reminders', 'Daily nudge to keep learning', true),
          _SettingRow('Show Leaderboard', 'Let others see your rank', true),
          _SettingRow('Auto-play Next Lesson', 'Continuous learning flow', false),
        ]);
      case 'settings':
        return (CupertinoIcons.gear_alt_fill, 'Settings', 'Customize your experience', [
          _SettingRow('Push Notifications', 'Get alerts for classes & assignments', true),
          _SettingRow('Email Digest', 'Weekly progress summary', true),
          const _DarkModeRow(),
          _SettingRow('Study Reminders', 'Daily nudge to keep learning', true),
          _SettingRow('Show Leaderboard', 'Let others see your rank', true),
          _SettingRow('Auto-play Next Lesson', 'Continuous learning flow', false),
        ]);
      case 'leaderboard':
        return (CupertinoIcons.list_number, 'Leaderboard', "This week's top learners", [
          _leader('1', 'Aryan Patel', '200 lessons', '1,240 XP'),
          _leader('2', 'Meera Iyer', '180 lessons', '1,100 XP'),
          _leader('3', '$_firstName (you)', '160 lessons', '980 XP', highlight: true),
          _leader('4', 'Ravi Kumar', '145 lessons', '870 XP'),
          _leader('5', 'Ananya Singh', '130 lessons', '760 XP'),
        ]);
      case 'schedule':
        return (CupertinoIcons.calendar, 'Calendar', 'Classes, deadlines & activities', [
          _future(_apiList('/api/v1/me/calendar', 'calendar'), (List items) {
            if (items.isEmpty) return _emptyText('Nothing scheduled yet.');
            return _CalendarView(items: items);
          }),
        ]);
      case 'progress':
        return (CupertinoIcons.chart_bar_fill, 'My Progress', 'Completion per course', [
          _future(_apiList('/api/v1/me/courses', 'my_courses'), (List courses) {
            if (courses.isEmpty) return _emptyText('No courses to track yet.');
            return Column(children: courses.map((c) {
              final m = c as Map<String, dynamic>;
              return _progress(m['title']?.toString() ?? 'Course', ((m['percent'] ?? 0) as num) / 100);
            }).toList());
          }),
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
            // Group by day_number; day-less items fall under "Unscheduled".
            final groups = <int?, List<Map<String, dynamic>>>{};
            for (final a in items) {
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
            final children = <Widget>[];
            for (final k in keys) {
              children.add(Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 4),
                child: Text(k == null ? 'Unscheduled' : 'Day $k',
                    style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700, color: _orange)),
              ));
              for (final m in groups[k]!) {
                final isQuiz = m['type'] == 'quiz';
                final submitted = m['submitted'] == true;
                final course = m['course']?.toString() ?? '';
                children.add(GestureDetector(
                  onTap: isQuiz && !submitted ? () => _openAssessment(m) : null,
                  child: _row(
                    isQuiz ? CupertinoIcons.question_square_fill : CupertinoIcons.doc_text_fill,
                    m['title']?.toString() ?? 'Assessment',
                    '$course · ${isQuiz ? 'Quiz' : 'Assignment'} · ${m['max_score'] ?? 100} pts',
                    submitted ? 'Submitted' : (isQuiz ? 'Start' : 'Pending'),
                    badgeBg: submitted ? _greenBg : null,
                    badgeFg: submitted ? _green : null,
                  ),
                ));
              }
            }
            return Column(children: children);
          }),
        ]);
      case 'resources':
        return (CupertinoIcons.bookmark_fill, 'Resources', 'Study materials', [
          _row(CupertinoIcons.doc_fill, 'HTML Cheat Sheet', 'PDF · 2.3 MB', 'Download'),
          _row(CupertinoIcons.play_rectangle_fill, 'CSS Flexbox Tutorial', 'Video · 45 min', 'Watch'),
          _row(CupertinoIcons.book_fill, 'Figma Handbook', 'PDF · 5.1 MB', 'Download'),
        ]);
      case 'certificates':
        return (CupertinoIcons.rosette, 'Certificates', 'Your achievements', [
          _future(_apiList('/api/v1/me/certificates', 'certificates'), (List certs) {
            if (certs.isEmpty) return _emptyText('No certificates yet — complete a course to earn one.');
            return Column(children: certs.map((c) {
              final m = c as Map<String, dynamic>;
              return _row(CupertinoIcons.rosette, m['course']?.toString() ?? 'Certificate', 'Issued ${_fmtAt(m['issued_at']?.toString())}', 'View');
            }).toList());
          }),
        ]);
      case 'live':
        return (CupertinoIcons.videocam_fill, 'Live Classes', 'Upcoming sessions', [
          _future(_apiList('/api/v1/me/live', 'live'), (List live) {
            if (live.isEmpty) return _emptyText('No live classes scheduled.');
            return Column(children: live.map((s) {
              final m = s as Map<String, dynamic>;
              final meta = [m['course']?.toString() ?? '', _fmtAt(m['starts_at']?.toString())].where((x) => x.isNotEmpty).join(' · ');
              return _row(CupertinoIcons.dot_radiowaves_left_right, m['title']?.toString() ?? 'Live class', meta, 'Join');
            }).toList());
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
            decoration: BoxDecoration(color: _peachSoft, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Current Plan', style: GoogleFonts.poppins(fontSize: 13, color: _grey)),
              const SizedBox(height: 4),
              Text('ONROL Pro', style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w700, color: _orange)),
              Text('Renews July 10, 2026', style: GoogleFonts.poppins(fontSize: 12, color: const Color(0xFFAAAAAA))),
            ]),
          ),
          const SizedBox(height: 14),
          _row(CupertinoIcons.doc_text, 'June 2026 — ₹999', 'Pro Plan · Paid', 'Paid', badgeBg: _greenBg, badgeFg: _green),
          _row(CupertinoIcons.doc_text, 'May 2026 — ₹999', 'Pro Plan · Paid', 'Paid', badgeBg: _greenBg, badgeFg: _green),
        ]);
      case 'notes':
        return (CupertinoIcons.pencil, 'My Notes', 'Quick study notes', [
          _notif('CSS Flexbox: justify-content aligns on main axis; align-items on cross axis.', 'Web Dev · Saved yesterday'),
          _notif('Figma: Auto Layout = CSS Flexbox for designers!', 'UI/UX · Saved 2 days ago'),
          const SizedBox(height: 16),
          _orangeButton('+ Add New Note', () => Navigator.of(context).pop()),
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
            return _CalendarView(items: items);
          }),
        ]);
      case 'announcements':
        return (CupertinoIcons.speaker_2_fill, 'Announcements', 'Latest from ONROL', [
          _notif('New course launched: Advanced React Patterns — enroll now!', '1 day ago'),
          _notif('Scheduled maintenance Sunday 2 AM–4 AM IST.', '2 days ago', read: true),
          _notif('Win prizes in the June coding challenge.', '3 days ago', read: true),
        ]);
      case 'forum':
        return (CupertinoIcons.bubble_left_bubble_right_fill, 'Discussion Forum', 'Join the conversation', [
          _row(CupertinoIcons.chat_bubble_2_fill, 'How do I center a div?', 'Web Development · 24 replies', 'Hot', badgeBg: const Color(0xFFFFF0EC), badgeFg: const Color(0xFFE05A2A)),
          _row(CupertinoIcons.paintbrush_fill, 'Best Figma plugins in 2026?', 'UI/UX Design · 12 replies', 'Open'),
          _row(CupertinoIcons.chart_bar_fill, 'Pandas vs NumPy — when?', 'Data Science · 8 replies', 'Open'),
        ]);
      case 'search':
        return (CupertinoIcons.search, 'Search', 'Find courses & lessons', [
          _field('SEARCH', ''),
          const SizedBox(height: 8),
          Text('Popular searches', style: GoogleFonts.poppins(fontSize: 12, color: const Color(0xFFAAAAAA), fontWeight: FontWeight.w600, letterSpacing: 0.5)),
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
          _future(_apiList('/api/v1/catalog', 'catalog'), (List cat) {
            if (cat.isEmpty) return _emptyText('No courses available right now.');
            // Group batch-wise (by category — the catalog's grouping field).
            final groups = <String, List>{};
            for (final c in cat) {
              final k = ((c as Map)['category']?.toString() ?? '').trim();
              groups.putIfAbsent(k.isEmpty ? 'General' : k, () => []).add(c);
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: groups.entries.expand<Widget>((e) => [
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Text(e.key, style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700, color: _orange)),
              ),
              ...e.value.map((c) {
                final m = c as Map<String, dynamic>;
                final self = m['enroll_type'] == 'self';
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _enrollCourse(m['id'].toString(), m['title']?.toString() ?? 'Course', self),
                  child: _row(CupertinoIcons.book_fill, m['title']?.toString() ?? 'Course', m['category']?.toString() ?? '', self ? 'Enroll' : 'Request'),
                );
              }),
            ]).toList());
          }),
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
                    gradient: const LinearGradient(colors: [_orange, Color(0xFFFF7A4D)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: _orange.withOpacity(0.35), blurRadius: 22, offset: const Offset(0, 10))],
                  ),
                  child: const Icon(CupertinoIcons.hand_raised_fill, size: 38, color: Colors.white),
                ),
              ),
              const SizedBox(height: 20),
              Text('Heading off, $_firstName?', textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700, color: _navy)),
              const SizedBox(height: 6),
              Text('Your progress is saved — jump back in anytime.',
                  textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 13.5, color: _grey, height: 1.5)),
              const SizedBox(height: 26),
              Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                // Compact "Stay" pill — subtle tinted.
                _Pressable(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
                    decoration: BoxDecoration(
                      color: _orange.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: _orange.withOpacity(0.28)),
                    ),
                    child: Text('Stay', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w700, color: _orange)),
                  ),
                ),
                const SizedBox(width: 12),
                // Compact "Log Out" gradient pill with icon + glow.
                _Pressable(
                  onTap: () { Navigator.of(context).pop(); _logout(); },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [_orange, Color(0xFFFF7A4D)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: [BoxShadow(color: _orange.withOpacity(0.40), blurRadius: 14, offset: const Offset(0, 6))],
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(CupertinoIcons.square_arrow_right, size: 16, color: Colors.white),
                      const SizedBox(width: 7),
                      Text('Log Out', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
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

Widget _progress(String label, double pct) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: GoogleFonts.poppins(fontSize: 13, color: _navy)),
          Text('${(pct * 100).round()}%', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: _orange)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          // Bar fills with a smooth animation when the panel opens.
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: pct.clamp(0.0, 1.0)),
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeOutCubic,
            builder: (_, v, __) => LinearProgressIndicator(
              value: v,
              minHeight: 8,
              backgroundColor: _isDark ? const Color(0xFF2C2F37) : const Color(0xFFF0EBE8),
              valueColor: const AlwaysStoppedAnimation(_orange),
            ),
          ),
        ),
      ]),
    );

Widget _notif(String text, String time, {bool read = false}) => _StudentHomeNotif(text: text, time: time, read: read);

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
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 10),
        // Minimal: transparent at rest, a light orange wash + hairline on hover.
        decoration: BoxDecoration(
          color: _hover ? _orange.withOpacity(0.06) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _hover ? _orange.withOpacity(0.18) : Colors.transparent, width: 1),
        ),
        child: Row(children: [
          Container(width: 44, height: 44, alignment: Alignment.center, decoration: BoxDecoration(color: _orange.withOpacity(0.12), borderRadius: BorderRadius.circular(8)), child: Icon(widget.icon, size: 20, color: _orange)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.name, style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: _navy)),
            Text(widget.meta, style: GoogleFonts.poppins(fontSize: 12, color: _grey)),
          ])),
          const SizedBox(width: 8),
          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: widget.badgeBg ?? _peach, borderRadius: BorderRadius.circular(20)),
              child: Text(widget.badge, style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600, color: widget.badgeFg ?? _orange))),
        ]),
      ),
    );
  }
}

Widget _leader(String rank, String name, String sub, String pts, {bool highlight = false}) => Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(color: highlight ? _peachSoft : null, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        SizedBox(width: 28, child: Text('#$rank', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700, color: _orange))),
        const SizedBox(width: 12),
        Container(width: 36, height: 36, alignment: Alignment.center, decoration: BoxDecoration(color: _orange.withOpacity(0.12), shape: BoxShape.circle), child: const Icon(CupertinoIcons.person_fill, size: 18, color: _orange)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: _navy)),
          Text(sub, style: GoogleFonts.poppins(fontSize: 12, color: _grey)),
        ])),
        Text(pts, style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700, color: _orange)),
      ]),
    );

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

String _dayLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${wd[d.weekday - 1]}, ${d.day} ${mo[d.month - 1]}';
}

String _timeLabel(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
}

Widget _calendarAgenda(List items) {
  // Group by calendar day, preserving the (already date-sorted) order.
  final groups = <String, List<Map<String, dynamic>>>{};
  final order = <String>[];
  final now = DateTime.now();
  for (final e in items) {
    final m = e as Map<String, dynamic>;
    final dt = DateTime.tryParse(m['at']?.toString() ?? '')?.toLocal();
    if (dt == null) continue;
    final key = '${dt.year}-${dt.month}-${dt.day}';
    if (!groups.containsKey(key)) {
      groups[key] = [];
      order.add(key);
    }
    groups[key]!.add({...m, '_dt': dt});
  }
  if (order.isEmpty) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Text('Nothing scheduled yet.', textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 13, color: _grey)),
    );
  }

  final out = <Widget>[];
  for (final key in order) {
    final dt0 = groups[key]!.first['_dt'] as DateTime;
    final isPast = DateTime(dt0.year, dt0.month, dt0.day).isBefore(DateTime(now.year, now.month, now.day));
    out.add(Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Text(_dayLabel(dt0).toUpperCase(),
          style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800, color: isPast ? _grey : _orange, letterSpacing: 0.5)),
    ));
    for (final m in groups[key]!) {
      final k = _calKind(m['kind']?.toString() ?? 'event');
      final dt = m['_dt'] as DateTime;
      final course = m['course']?.toString() ?? '';
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40, height: 40, alignment: Alignment.center,
            decoration: BoxDecoration(color: k.color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
            child: Icon(k.icon, size: 19, color: k.color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m['title']?.toString() ?? 'Event', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: _navy)),
              Text([k.label, if (course.isNotEmpty) course].join(' · '), style: GoogleFonts.inter(fontSize: 12, color: _grey)),
            ]),
          ),
          const SizedBox(width: 8),
          Text(_timeLabel(dt), style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _grey)),
        ]),
      ));
    }
  }
  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: out);
}

const _monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Live month calendar — dots per day for classes / deadlines / activities; tap
/// a day to see its agenda. Smooth month + day-selection transitions, themed.
class _CalendarView extends StatefulWidget {
  const _CalendarView({required this.items});
  final List items;

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
        Expanded(child: Center(child: Text('${_monthNames[_month.month - 1]} ${_month.year}', style: GoogleFonts.poppins(fontSize: 17, fontWeight: FontWeight.w800, color: _navy)))),
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
      Row(children: _weekdayNames.map((w) => Expanded(child: Center(child: Text(w, style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600, color: _grey))))).toList()),
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
        Expanded(child: Text('${_weekdayNames[(_selected.weekday - 1) % 7]}, ${_monthNames[_selected.month - 1]} ${_selected.day}', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w700, color: _navy))),
        if (selEvs.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(color: _orange.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
            child: Text('${selEvs.length} ${selEvs.length == 1 ? 'event' : 'events'}', style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w700, color: _orange)),
          ),
      ]),
      const SizedBox(height: 12),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        child: KeyedSubtree(key: ValueKey(_k(_selected)), child: _agenda(selEvs)),
      ),
    ]);
  }

  Widget _navBtn(IconData ic, VoidCallback onTap) => _Pressable(
        onTap: onTap,
        child: Container(
          width: 38, height: 38, alignment: Alignment.center,
          decoration: BoxDecoration(color: _orange.withOpacity(0.10), borderRadius: BorderRadius.circular(12)),
          child: Icon(ic, size: 18, color: _orange),
        ),
      );

  Widget _sumChip(String label, int n, Color color, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(color: color.withOpacity(0.10), borderRadius: BorderRadius.circular(16), border: Border.all(color: color.withOpacity(0.22))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: n.toDouble()),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (_, v, __) => Text('${v.round()}', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
            ),
          ]),
          const SizedBox(height: 2),
          Text(label, style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w500, color: _grey)),
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
          decoration: BoxDecoration(color: _orange.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(CupertinoIcons.calendar_today, size: 14, color: _orange),
            const SizedBox(width: 6),
            Text('Today', style: GoogleFonts.poppins(fontSize: 12.5, fontWeight: FontWeight.w700, color: _orange)),
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
            gradient: isSel ? const LinearGradient(colors: [_orange, Color(0xFFFF7A4D)], begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
            color: isSel ? null : (isToday ? _orange.withOpacity(0.12) : Colors.transparent),
            borderRadius: BorderRadius.circular(13),
            border: isToday && !isSel ? Border.all(color: _orange.withOpacity(0.6), width: 1.4) : null,
            boxShadow: isSel ? [BoxShadow(color: _orange.withOpacity(0.40), blurRadius: 12, offset: const Offset(0, 5))] : const [],
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('${d.day}', style: GoogleFonts.poppins(fontSize: 13, fontWeight: isSel || isToday ? FontWeight.w700 : FontWeight.w500, color: isSel ? Colors.white : _navy)),
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
          Text('Nothing scheduled', style: GoogleFonts.poppins(fontSize: 13.5, fontWeight: FontWeight.w600, color: _navy)),
          const SizedBox(height: 2),
          Text('Enjoy the free time, or browse the catalog.', textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 12, color: _grey)),
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
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: _cardFill, borderRadius: BorderRadius.circular(14), border: Border.all(color: _cardBorder), boxShadow: [BoxShadow(color: Colors.black.withOpacity(_isDark ? 0.0 : 0.04), blurRadius: 8, offset: const Offset(0, 3))]),
              child: IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(width: 4, color: k.color),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(width: 40, height: 40, alignment: Alignment.center, decoration: BoxDecoration(color: k.color.withOpacity(0.14), borderRadius: BorderRadius.circular(10)), child: Icon(k.icon, size: 19, color: k.color)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(m['title']?.toString() ?? 'Event', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: _navy)),
                            const SizedBox(height: 3),
                            Row(children: [
                              Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: k.color.withOpacity(0.12), borderRadius: BorderRadius.circular(20)), child: Text(k.label, style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w700, color: k.color))),
                              if (course.isNotEmpty) ...[const SizedBox(width: 6), Flexible(child: Text(course, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(fontSize: 12, color: _grey)))],
                            ]),
                          ]),
                        ),
                        const SizedBox(width: 8),
                        Text(_timeLabel(dt), style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600, color: _grey)),
                      ]),
                    ),
                  ),
                ]),
              ),
            );
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
          Text(q, style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700, color: _navy)),
          const SizedBox(height: 3),
          Text(a, style: GoogleFonts.poppins(fontSize: 12, color: _grey, height: 1.4)),
        ])),
      ]),
    );

Widget _field(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: GoogleFonts.poppins(fontSize: 12, color: const Color(0xFFAAAAAA), fontWeight: FontWeight.w600, letterSpacing: 0.5)),
        const SizedBox(height: 5),
        TextFormField(
          initialValue: value,
          style: GoogleFonts.poppins(fontSize: 14, color: _navy),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFEEEEEE), width: 1.5)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _orange, width: 1.5)),
          ),
        ),
      ]),
    );

Widget _orangeButton(String label, VoidCallback onTap) => _Pressable(
      onTap: onTap,
      child: Container(
        width: double.infinity, height: 46, alignment: Alignment.center,
        decoration: BoxDecoration(color: _orange, borderRadius: BorderRadius.circular(10)),
        child: Text(label, style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
      ),
    );

Widget _outlineButton(String label, VoidCallback onTap) => _Pressable(
      onTap: onTap,
      child: Container(
        height: 46, alignment: Alignment.center,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: _orange, width: 2)),
        child: Text(label, style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: _orange)),
      ),
    );

/// Profile panel — loads the caller's profile from the API and saves edits.
class _ProfilePanel extends StatefulWidget {
  const _ProfilePanel({required this.auth});
  final AuthService auth;

  @override
  State<_ProfilePanel> createState() => _ProfilePanelState();
}

class _ProfilePanelState extends State<_ProfilePanel> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  String _email = '';
  String _role = 'student';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final m = ApiClient.decode(await widget.auth.apiGet('/api/v1/me/profile'));
      _name.text = m['full_name']?.toString() ?? '';
      _phone.text = m['phone']?.toString() ?? '';
      _email = m['email']?.toString() ?? '';
      _role = m['role']?.toString() ?? 'student';
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.auth.apiPatch('/api/v1/me/profile', {
        'full_name': _name.text.trim(),
        if (_phone.text.trim().isNotEmpty) 'phone': _phone.text.trim(),
      });
      await widget.auth.refreshProfile();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile saved'), behavior: SnackBarBehavior.floating));
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _ctlField(String label, TextEditingController c, {bool enabled = true}) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: GoogleFonts.poppins(fontSize: 12, color: const Color(0xFFAAAAAA), fontWeight: FontWeight.w600, letterSpacing: 0.5)),
          const SizedBox(height: 5),
          TextField(
            controller: c,
            enabled: enabled,
            style: GoogleFonts.poppins(fontSize: 14, color: _navy),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFEEEEEE), width: 1.5)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: _orange, width: 1.5)),
              disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFF0F0F0), width: 1.5)),
            ),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 34), child: Center(child: CircularProgressIndicator(color: _orange, strokeWidth: 2.5)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Center(
        child: Container(
          width: 80, height: 80, alignment: Alignment.center,
          decoration: BoxDecoration(color: _orange.withOpacity(0.12), shape: BoxShape.circle, border: Border.all(color: _orange, width: 3)),
          child: const Icon(CupertinoIcons.person_fill, size: 36, color: _orange),
        ),
      ),
      const SizedBox(height: 16),
      Center(child: Text(_name.text, style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700, color: _navy))),
      Center(child: Text('${_role[0].toUpperCase()}${_role.substring(1)} · ONROL', style: GoogleFonts.poppins(fontSize: 13, color: _orange))),
      const SizedBox(height: 20),
      _ctlField('FULL NAME', _name),
      _ctlField('EMAIL', TextEditingController(text: _email), enabled: false),
      _ctlField('PHONE', _phone),
      const SizedBox(height: 8),
      _Pressable(
        onTap: _saving ? () {} : _save,
        child: Container(
          width: double.infinity, height: 46, alignment: Alignment.center,
          decoration: BoxDecoration(color: _orange, borderRadius: BorderRadius.circular(10)),
          child: _saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
              : Text('Save Changes', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
        ),
      ),
    ]);
  }
}

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

  @override
  void initState() {
    super.initState();
    _load();
    // Pull fresh headlines every 90s (backend is cached, so this is cheap)…
    _poll = Timer.periodic(const Duration(seconds: 90), (_) => _load());
    // …and re-render every 30s so the relative times & LIVE badges stay live
    // even between fetches.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
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
      final res = await widget.auth.apiGet('/api/v1/news?category=ai');
      final data = ApiClient.decode(res);
      final list = ((data['news'] as List?) ?? [])
          .map((e) => _News.fromJson(e as Map<String, dynamic>))
          .where((n) => n.title.isNotEmpty && n.url.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _items = list;
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
    return _glass(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: widget.scrollable ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Row(children: [
            Icon(CupertinoIcons.sparkles, size: 18, color: _orange),
            const SizedBox(width: 8),
            Text('UPDATE ', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w800, color: _navy)),
            Text('LIVE AI NEWS', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w800, color: _orange)),
            const Spacer(),
            _livePill(),
          ]),
          const SizedBox(height: 10),
          if (widget.scrollable) Expanded(child: _body()) else _body(),
        ],
      ),
    );
  }

  // Loading / fallback / list — the only part that varies by state.
  Widget _body() {
    final items = _items;
    if (items == null && !_failed) return _statusBox(loading: true);
    if ((items == null || items.isEmpty)) return _statusBox(loading: false);

    final rows = <Widget>[
      for (var i = 0; i < items.length; i++) _newsRow(items[i], last: i == items.length - 1),
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
              Text('Live news unavailable', textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: _navy)),
              const SizedBox(height: 2),
              Text('Pull again in a moment.', textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 12, color: _grey)),
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
          decoration: BoxDecoration(color: _orange.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _refreshing
                ? const SizedBox(width: 9, height: 9, child: CircularProgressIndicator(strokeWidth: 1.6, color: _orange))
                : const _LiveDot(),
            const SizedBox(width: 5),
            Text('LIVE', style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w800, color: _orange, letterSpacing: 0.5)),
          ]),
        ),
      );

  Widget _newsRow(_News n, {required bool last}) {
    final live = n.isLive;
    return InkWell(
      onTap: () => _open(n.url),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: _line))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 56, height: 56, alignment: Alignment.center,
            decoration: BoxDecoration(color: _peach, borderRadius: BorderRadius.circular(12)),
            child: Icon(n.icon, size: 26, color: _orange),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // LIVE badge for recent items; otherwise the source name.
              if (live)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 6, height: 6, decoration: const BoxDecoration(color: _orange, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text('LIVE', style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w800, color: _orange, letterSpacing: 0.5)),
                ])
              else
                Text(n.source.toUpperCase(), style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w800, color: _orange, letterSpacing: 0.5)),
              const SizedBox(height: 4),
              Text(n.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(fontSize: 13.5, fontWeight: FontWeight.w700, color: _navy, height: 1.3)),
              const SizedBox(height: 4),
              Text(
                [n.source, if (n.ago.isNotEmpty) n.ago].join(' · '),
                style: GoogleFonts.poppins(fontSize: 11.5, color: _grey),
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
            boxShadow: [BoxShadow(color: _orange.withOpacity(0.55 * t), blurRadius: 6 * t, spreadRadius: 1.5 * t)],
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
          transitionDuration: const Duration(milliseconds: 460),
          reverseTransitionDuration: const Duration(milliseconds: 360),
          pageBuilder: (ctx, anim, sec) => child,
          // Motion is handled by the Hero + the in-page animations.
          transitionsBuilder: (ctx, anim, sec, c) => c,
        );
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
        return Stack(children: [
          // Blur + dim the dashboard behind (animated with the route). Tap to close.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(ctx).maybePop(),
              child: AnimatedBuilder(
                animation: anim,
                builder: (_, __) {
                  final v = Curves.easeOut.transform(anim.value.clamp(0.0, 1.0));
                  return BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 22 * v, sigmaY: 22 * v),
                    child: Container(color: Colors.black.withOpacity(0.34 * v)),
                  );
                },
              ),
            ),
          ),
          Center(
            child: compact
                ? Padding(
                    padding: EdgeInsets.symmetric(horizontal: size.width < 480 ? 24 : 0, vertical: 40),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: 420, maxHeight: size.height * 0.85),
                      child: _card(ctx, anim),
                    ),
                  )
                : SizedBox(
                    width: size.width * 0.97,
                    height: size.height * 0.97,
                    child: _card(ctx, anim),
                  ),
          ),
        ]);
      },
    );
  }

  Widget _card(BuildContext ctx, Animation<double> anim) {
    // The gradient header is the shared element that morphs from the tile.
    final header = Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 16, 18, 16),
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [_orange, Color(0xFFFF7A4D)], begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Row(children: [
          _Pressable(
            onTap: () => Navigator.of(ctx).maybePop(),
            child: Container(
              width: 34, height: 34, alignment: Alignment.center,
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.22), borderRadius: BorderRadius.circular(10)),
              child: const Icon(CupertinoIcons.chevron_back, size: 20, color: Colors.white),
            ),
          ),
          const SizedBox(width: 12),
          Icon(icon, size: 26, color: Colors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(fontSize: 12, color: Colors.white.withOpacity(0.9))),
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
            borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(_isDark ? 0.5 : 0.25), blurRadius: 48, offset: const Offset(0, 22))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 26, sigmaY: 26),
              child: Container(
                width: double.infinity,
                // Frosted-glass card — translucent so the blurred dashboard
                // refracts through; white element cards stay crisp on top.
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: _isDark
                        ? [const Color(0xFF22242D).withOpacity(0.82), const Color(0xFF181A22).withOpacity(0.70)]
                        : [Colors.white.withOpacity(0.74), Colors.white.withOpacity(0.60)],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: _isDark ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.70), width: 1.2),
                ),
                child: Column(
                  mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
              heroTag != null ? Hero(tag: heroTag!, child: header) : header,
              Flexible(
                fit: compact ? FlexFit.loose : FlexFit.tight,
                child: FadeTransition(
                  opacity: CurvedAnimation(parent: anim, curve: const Interval(0.35, 1.0, curve: Curves.easeOut)),
                  child: SlideTransition(
                    position: Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero)
                        .animate(CurvedAnimation(parent: anim, curve: const Interval(0.35, 1.0, curve: Curves.easeOutCubic))),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
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

/// Staggered fade + slide entrance for list items.
class _Entrance extends StatefulWidget {
  const _Entrance({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 440));
  late final Animation<double> _fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween<Offset>(begin: const Offset(0, 0.10), end: Offset.zero).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: 70 * widget.index), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _fade, child: SlideTransition(position: _slide, child: widget.child));
}

/// A rich course card: gradient cover, animated progress bar, hover lift.
class _CourseCard extends StatefulWidget {
  const _CourseCard({required this.index, required this.title, required this.done, required this.total, required this.percent, required this.onOpen});
  final int index;
  final String title;
  final int done;
  final int total;
  final int percent;
  final VoidCallback onOpen;

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
            color: _cardFill,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _hover ? _orange.withOpacity(0.40) : _cardBorder, width: 1),
            boxShadow: [BoxShadow(color: _orange.withOpacity(_hover ? 0.22 : 0.07), blurRadius: _hover ? 22 : 12, offset: Offset(0, _hover ? 9 : 5))],
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Gradient cover with the book glyph + a faint completion ring.
            Container(
              width: 58, height: 58, alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: cover, begin: Alignment.topLeft, end: Alignment.bottomRight),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: cover.last.withOpacity(0.35), blurRadius: 10, offset: const Offset(0, 4))],
              ),
              child: const Icon(CupertinoIcons.book_fill, size: 24, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700, color: _navy))),
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
                  Text('${widget.done}/${widget.total} lessons', style: GoogleFonts.poppins(fontSize: 12, color: _grey)),
                  const Spacer(),
                  Text('${widget.percent}%', style: GoogleFonts.poppins(fontSize: 12.5, fontWeight: FontWeight.w700, color: _orange)),
                ]),
                const SizedBox(height: 9),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: pct),
                    duration: const Duration(milliseconds: 800),
                    curve: Curves.easeOutCubic,
                    builder: (_, v, __) => LinearProgressIndicator(
                      value: v,
                      minHeight: 7,
                      backgroundColor: _isDark ? const Color(0xFF2C2F37) : const Color(0xFFF0EBE8),
                      valueColor: const AlwaysStoppedAnimation(_orange),
                    ),
                  ),
                ),
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
            // Tinted-glass tile: translucent orange so the backdrop glows
            // through, a hairline highlight edge, and an orange lift on hover.
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: _hover
                    ? [const Color(0xFFFF7A4D).withOpacity(0.94), _orange.withOpacity(0.84)]
                    : [_orange.withOpacity(0.92), const Color(0xFFE8421F).withOpacity(0.82)],
              ),
              boxShadow: [
                BoxShadow(
                  color: _orange.withOpacity(active ? 0.55 : 0.20),
                  blurRadius: active ? 28 : 14,
                  spreadRadius: active ? 1 : 0,
                  offset: Offset(0, active ? 12 : 6),
                ),
              ],
            ),
            // Glossy top sheen.
            foregroundDecoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white.withOpacity(0.16), Colors.white.withOpacity(0.0)],
                stops: const [0.0, 0.55],
              ),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
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
                      child: Icon(t.icon, color: Colors.white, size: 30),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(t.label,
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A settings row with an animated toggle.
class _SettingRow extends StatefulWidget {
  const _SettingRow(this.label, this.sub, this.initial);
  final String label;
  final String sub;
  final bool initial;

  @override
  State<_SettingRow> createState() => _SettingRowState();
}

class _SettingRowState extends State<_SettingRow> {
  late bool _on = widget.initial;

  @override
  Widget build(BuildContext context) =>
      _toggleRowView(widget.label, widget.sub, _on, () => setState(() => _on = !_on));
}

/// Shared visual for a labelled toggle row.
Widget _toggleRowView(String label, String sub, bool on, VoidCallback onTap) => Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _line))),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: GoogleFonts.poppins(fontSize: 14, color: _navy)),
          Text(sub, style: GoogleFonts.poppins(fontSize: 12, color: _grey)),
        ])),
        GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 44, height: 24,
            decoration: BoxDecoration(color: on ? _orange : _line, borderRadius: BorderRadius.circular(12)),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: on ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(width: 18, height: 18, margin: const EdgeInsets.symmetric(horizontal: 3), decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
            ),
          ),
        ),
      ]),
    );

/// Dark Mode toggle — switches the app theme via [setTheme].
class _DarkModeRow extends StatelessWidget {
  const _DarkModeRow();
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (ctx, mode, _) {
        final on = mode == ThemeMode.dark ||
            (mode == ThemeMode.system && MediaQuery.platformBrightnessOf(ctx) == Brightness.dark);
        return _toggleRowView('Dark Mode', 'Easy on the eyes at night', on,
            () => setTheme(on ? ThemeMode.light : ThemeMode.dark));
      },
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
              // Highlights with a soft orange wash + glow on hover.
              color: _hover ? Color.alphaBlend(_orange.withOpacity(0.10), _cardFill) : _cardFill,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _hover ? _orange.withOpacity(0.55) : _cardBorder, width: _hover ? 1.5 : 1),
              boxShadow: [BoxShadow(color: _orange.withOpacity(_hover ? 0.24 : 0.06), blurRadius: _hover ? 22 : 10, offset: const Offset(0, 6))],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (widget.icon != null)
                  Container(
                    width: 30, height: 30, alignment: Alignment.center,
                    decoration: BoxDecoration(color: _orange.withOpacity(0.12), borderRadius: BorderRadius.circular(9)),
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
                  style: GoogleFonts.poppins(fontSize: 26, fontWeight: FontWeight.w800, color: _orange),
                ),
              ),
              const SizedBox(height: 2),
              Text(widget.label, style: GoogleFonts.poppins(fontSize: 12.5, fontWeight: FontWeight.w500, color: _grey)),
            ]),
          ),
        ),
      );
  }
}

/// A notification row that expands on tap to reveal the full text. Themed glass
/// chip with a rotating chevron.
class _StudentHomeNotif extends StatefulWidget {
  const _StudentHomeNotif({required this.text, required this.time, this.read = false});
  final String text;
  final String time;
  final bool read;

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
            color: active ? Color.alphaBlend(_orange.withOpacity(0.06), _cardFill) : _cardFill,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: active ? _orange.withOpacity(0.30) : _cardBorder, width: 1),
            boxShadow: active ? [BoxShadow(color: _orange.withOpacity(0.10), blurRadius: 12, offset: const Offset(0, 4))] : const [],
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 8, height: 8, margin: const EdgeInsets.only(top: 6, right: 12), decoration: BoxDecoration(color: widget.read ? _grey : _orange, shape: BoxShape.circle)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topLeft,
                  child: Text(
                    widget.text,
                    maxLines: _open ? null : 2,
                    overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(fontSize: 13, color: _navy, height: 1.5),
                  ),
                ),
                const SizedBox(height: 4),
                Text(widget.time, style: GoogleFonts.poppins(fontSize: 11, color: _grey)),
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
  final VoidCallback onTap;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final scale = _down ? 0.96 : (_hover ? 1.03 : 1.0);
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
        onTap: widget.onTap,
        child: AnimatedScale(scale: scale, duration: const Duration(milliseconds: 140), curve: Curves.easeOutCubic, child: widget.child),
      ),
    );
  }
}
