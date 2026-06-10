import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/matrix_shell.dart';
import '../widgets/profile_view.dart';
import '../widgets/ui.dart';
import 'course_detail_screen.dart';
import 'live_screen.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.auth});
  final AuthService auth;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loading = true;

  Map<String, dynamic> _transcript = {};
  List<dynamic> _courses = [];
  List<dynamic> _catalog = [];
  List<dynamic> _live = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.auth.apiGet('/api/v1/me/transcript'),
        widget.auth.apiGet('/api/v1/me/courses'),
        widget.auth.apiGet('/api/v1/catalog'),
        widget.auth.apiGet('/api/v1/me/live'),
      ]);
      _transcript = ApiClient.decode(results[0]);
      _courses = (ApiClient.decode(results[1])['my_courses'] as List?) ?? [];
      _catalog = (ApiClient.decode(results[2])['catalog'] as List?) ?? [];
      _live = (ApiClient.decode(results[3])['live'] as List?) ?? [];
    } catch (_) {
      // Leave empty states; the dashboard still renders.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _joinSession(String url) {
    if (url.isEmpty) {
      _toast('No link for this session yet.');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LiveScreen(url: url, watermark: widget.auth.user?.email ?? 'student'),
    ));
  }

  Future<void> _enroll(String courseId, String title) async {
    try {
      final r = await widget.auth.apiPost('/api/v1/me/courses/$courseId/enroll', {});
      final d = ApiClient.decode(r);
      _toast(d['enrolled'] == true ? 'Enrolled in $title' : 'Enrollment requested for $title');
      _load();
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Could not enroll.');
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), behavior: SnackBarBehavior.floating),
      );

  Future<void> _logout() async {
    await widget.auth.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth)));
  }

  String get _firstName {
    final n = widget.auth.user?.fullName ?? widget.auth.user?.email ?? 'there';
    return n.split(RegExp(r'[\s@]')).first;
  }

  @override
  Widget build(BuildContext context) {
    return MatrixShell(
      title: 'ONROL',
      subtitle: 'Hi, $_firstName',
      items: [
        MatrixItem(icon: CupertinoIcons.house_fill, label: 'Home', color: AppleColors.blue, page: _dashboardPage()),
        MatrixItem(icon: CupertinoIcons.person_fill, label: 'Profile', color: AppleColors.purple, page: _profilePage()),
      ],
    );
  }

  Widget _dashboardPage() {
    final p = Palette.of(context);
    final w = MediaQuery.of(context).size.width;
    final hPad = w > 712 ? (w - 680) / 2 : 18.0;
    return RefreshIndicator(
      color: p.accent,
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(hPad.clamp(18, 400), 18, hPad.clamp(18, 400), 40),
        children: [
          Text('Hi, $_firstName', style: AppleTheme.largeTitle(context)),
          const SizedBox(height: 2),
          Text('Welcome back to ONROL Learn', style: AppleTheme.subhead(context)),
          const SizedBox(height: 20),
          _statsRow(),
          if (_live.isNotEmpty) ...[
            const SizedBox(height: 24),
            _liveSection(),
          ],
          const SizedBox(height: 24),
          _myCourses(),
          if (_catalog.isNotEmpty) ...[
            const SizedBox(height: 24),
            _catalogSection(),
          ],
        ],
      ),
    );
  }

  Widget _profilePage() => ProfileView(auth: widget.auth, onSignOut: _logout);

  Widget _statsRow() {
    final enrolled = '${_transcript['enrolled'] ?? 0}';
    final completed = '${_transcript['completed'] ?? 0}';
    final certs = '${_transcript['certificates'] ?? 0}';
    return Row(
      children: [
        Expanded(child: StatTile(value: enrolled, label: 'Enrolled', icon: CupertinoIcons.book, color: AppleColors.blue)),
        const SizedBox(width: 12),
        Expanded(child: StatTile(value: completed, label: 'Completed', icon: CupertinoIcons.checkmark_seal_fill, color: AppleColors.green)),
        const SizedBox(width: 12),
        Expanded(child: StatTile(value: certs, label: 'Certificates', icon: CupertinoIcons.rosette, color: AppleColors.orange)),
      ],
    );
  }

  Widget _liveSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Live Classes'),
        ..._live.map((s) {
          final m = s as Map<String, dynamic>;
          final hasLink = (m['join_url']?.toString() ?? '').isNotEmpty;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: AppleCard(
              child: Row(children: [
                Stack(alignment: Alignment.center, children: [
                  Container(
                    width: 42, height: 42,
                    decoration: BoxDecoration(color: AppleColors.red.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
                    child: const Icon(CupertinoIcons.dot_radiowaves_left_right, color: AppleColors.red, size: 20),
                  ),
                ]),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(m['title']?.toString() ?? 'Live class', style: AppleTheme.headline(context)),
                    Text('${m['course'] ?? ''} · ${_fmtSessionTime(m['starts_at']?.toString())}', style: AppleTheme.footnote(context)),
                  ]),
                ),
                GestureDetector(
                  onTap: () => _joinSession(m['join_url']?.toString() ?? ''),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    decoration: BoxDecoration(
                      color: hasLink ? AppleColors.red : Palette.of(context).secondary,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Text('Join', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                ),
              ]),
            ),
          );
        }),
      ],
    );
  }

  String _fmtSessionTime(String? iso) {
    if (iso == null || iso.isEmpty) return 'Time TBD';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${months[dt.month - 1]} ${dt.day}, $h:${dt.minute.toString().padLeft(2, '0')} $ampm';
  }

  Widget _myCourses() {
    if (_loading) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 28), child: Center(child: CupertinoActivityIndicator()));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Continue Learning'),
        if (_courses.isEmpty)
          AppleCard(
            child: Column(
              children: [
                const Icon(CupertinoIcons.square_stack_3d_up, size: 34, color: AppleColors.blue),
                const SizedBox(height: 10),
                Text('No courses yet', style: AppleTheme.headline(context)),
                const SizedBox(height: 4),
                Text('Browse the catalog below to enroll.', style: AppleTheme.footnote(context), textAlign: TextAlign.center),
              ],
            ),
          )
        else
          checkerboardTiles(context, _courses.map((c) => _courseCard(c as Map<String, dynamic>)).toList()),
      ],
    );
  }

  Widget _courseCard(Map<String, dynamic> c) {
    final pct = (c['percent'] ?? 0) as int;
    final done = c['lessons_done'] ?? 0;
    final total = c['lessons_total'] ?? 0;
    final completed = c['status'] == 'completed';
    return AppleCard(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => CourseDetailScreen(auth: widget.auth, courseId: c['id'].toString(), title: c['title']?.toString() ?? 'Course'),
        )).then((_) => _load()),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(c['title']?.toString() ?? 'Course', style: AppleTheme.headline(context), maxLines: 2, overflow: TextOverflow.ellipsis)),
                Icon(completed ? CupertinoIcons.checkmark_seal_fill : CupertinoIcons.chevron_right,
                    color: completed ? AppleColors.green : Palette.of(context).secondary, size: completed ? 20 : 18),
              ],
            ),
            const SizedBox(height: 12),
            AppleProgress(value: pct / 100, color: completed ? AppleColors.green : null),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: Text('$done/$total lessons', style: AppleTheme.footnote(context), overflow: TextOverflow.ellipsis)),
                Text('$pct%', style: AppleTheme.footnote(context).copyWith(color: Palette.of(context).accent, fontWeight: FontWeight.w700)),
              ],
            ),
          ],
        ),
      );
  }

  Widget _catalogSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Course Catalog'),
        checkerboardTiles(context, _catalog.take(8).map((c) => _catalogCard(c as Map<String, dynamic>)).toList()),
      ],
    );
  }

  Widget _catalogCard(Map<String, dynamic> m) {
    final selfEnroll = m['enroll_type'] == 'self';
    return AppleCard(
      onTap: () => _enroll(m['id'].toString(), m['title'].toString()),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: AppleColors.blue.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
            child: const Icon(CupertinoIcons.book_fill, color: AppleColors.blue, size: 22),
          ),
          const SizedBox(height: 12),
          Text(m['title']?.toString() ?? 'Course', style: AppleTheme.headline(context), maxLines: 2, overflow: TextOverflow.ellipsis),
          if ((m['category']?.toString() ?? '').isNotEmpty) Text(m['category'].toString(), style: AppleTheme.footnote(context), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(color: Palette.of(context).accent, borderRadius: BorderRadius.circular(13)),
              child: Text(selfEnroll ? 'Enroll' : 'Request', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}
