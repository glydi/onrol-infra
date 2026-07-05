import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/download_stub.dart' if (dart.library.html) '../widgets/download_web.dart';
import '../widgets/markdown_view.dart';
import '../widgets/profile_view.dart';
import '../widgets/ui.dart';
import 'admin_calendar_screen.dart';
import 'discussion_screen.dart';
import 'live_session_screen.dart';
import 'login_screen.dart';
import 'video_store_screen.dart';

/// Mentor/Admin management console — author courses, lessons and enrollments.
class ConsoleScreen extends StatefulWidget {
  const ConsoleScreen({super.key, required this.auth});
  final AuthService auth;

  @override
  State<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends State<ConsoleScreen> {
  bool _loading = true;
  List<dynamic> _courses = [];
  List<dynamic> _requests = [];
  List<dynamic> _people = [];
  String _peopleQuery = ''; // People-tab search across all users

  bool get _isAdmin => widget.auth.user?.role == 'manager' || widget.auth.user?.role == 'superadmin';

  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // Keep the console (courses, people, the unassigned queue) fresh as the DB is
    // populated externally — auto-provisioning, the CRM, etc.
    _refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  // [quiet] = background refresh: no spinner, keep current data on failure.
  Future<void> _load({bool quiet = false}) async {
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/courses');
      _courses = (ApiClient.decode(r)['courses'] as List?) ?? _courses;
      final q = await widget.auth.apiGet('/api/v1/manage/enrollment-requests');
      _requests = (ApiClient.decode(q)['requests'] as List?) ?? _requests;
      if (_isAdmin) {
        final u = await widget.auth.apiGet('/api/v1/manage/users');
        _people = (ApiClient.decode(u)['users'] as List?) ?? _people;
      }
    } catch (_) {
      if (quiet) return; // leave existing data untouched on a background refresh
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _decideRequest(String id, String action) async {
    try {
      await widget.auth.apiPost('/api/v1/manage/enrollment-requests/$id/$action', {});
      _toast(action == 'approve' ? 'Student enrolled' : 'Request rejected');
      _load();
    } catch (_) {
      _toast('Could not $action');
    }
  }

  Future<void> _togglePublish(String courseId, bool publish) async {
    try {
      await widget.auth.apiPatch('/api/v1/manage/courses/$courseId', {'status': publish ? 'published' : 'draft'});
      _toast(publish ? 'Published — students can see it now' : 'Unpublished');
      _load();
    } catch (_) {
      _toast('Could not update');
    }
  }

  Future<void> _setCourseStatus(String courseId, String status) async {
    try {
      await widget.auth.apiPatch('/api/v1/manage/courses/$courseId', {'status': status});
      _toast(status == 'archived' ? 'Course archived' : 'Course restored to draft');
      _load();
    } catch (_) {
      _toast('Could not update');
    }
  }

  Future<void> _deleteCourse(String courseId, String title) async {
    final yes = await showSquareConfirm(context,
        title: 'Delete course',
        message: 'Delete "$title" and all its content permanently? This cannot be undone. Consider archiving instead.',
        confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/courses/$courseId');
      _toast('Course deleted');
      _load();
    } catch (_) {
      _toast('Could not delete');
    }
  }

  // Archive / restore / delete a course via a squared popup menu.
  Future<void> _courseMenu(Map<String, dynamic> c) async {
    final id = c['id'].toString();
    final title = c['title']?.toString() ?? 'Course';
    final archived = (c['status']?.toString() ?? '') == 'archived';
    final v = await showSquareMenu(context, title: title, items: [
      const SquareMenuItem('View batches', value: 'batches', icon: CupertinoIcons.square_stack_3d_up),
      SquareMenuItem(archived ? 'Restore to draft' : 'Archive course', value: 'archive', icon: CupertinoIcons.archivebox),
      const SquareMenuItem('Delete course', value: 'delete', icon: CupertinoIcons.trash, destructive: true),
    ]);
    if (!mounted) return;
    if (v == 'batches') {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CourseBatchesScreen(auth: widget.auth, courseId: id, title: title),
      ));
    } else if (v == 'archive') {
      archived ? _setCourseStatus(id, 'draft') : _setCourseStatus(id, 'archived');
    } else if (v == 'delete') {
      _deleteCourse(id, title);
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  Future<void> _logout() async {
    await widget.auth.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth)));
  }


  @override
  Widget build(BuildContext context) {
    final dests = <NavDest>[
      const NavDest(CupertinoIcons.square_list_fill, 'Courses'),
      if (_isAdmin) const NavDest(CupertinoIcons.person_2_fill, 'People'),
      if (_isAdmin) const NavDest(CupertinoIcons.calendar, 'Calendar'),
      const NavDest(CupertinoIcons.person_fill, 'Profile'),
    ];
    final pages = <Widget>[
      _consolePage(),
      if (_isAdmin) _peoplePage(),
      if (_isAdmin) AdminCalendarScreen(auth: widget.auth),
      _profilePage(),
    ];
    // The whole admin console renders with squared corners.
    return SquareScope(
      child: AppShell(
        auth: widget.auth,
        onSignOut: _logout,
        trailing: _isAdmin ? _newCourseButton() : null,
        destinations: dests,
        pages: pages,
      ),
    );
  }

  Widget _peoplePage() {
    final hp = _hPad(context);
    final instructors = _people.where((u) => u['role'] == 'instructor').toList();
    final students = _people.where((u) => u['role'] == 'student').toList();
    final others = _people.where((u) => u['role'] == 'manager' || u['role'] == 'superadmin').toList();
    return RefreshIndicator(
      color: Palette.of(context).accent,
      onRefresh: _load,
      child: ListView(
      padding: EdgeInsets.fromLTRB(hp, 18, hp, 40),
      children: [
        Row(children: [
          Expanded(child: Text('People', style: AppleTheme.largeTitle(context))),
          HoverTap(onTap: _load, child: Icon(CupertinoIcons.arrow_clockwise, color: Palette.of(context).accent, size: 24)),
        ]),
        Text('Create and manage accounts', style: AppleTheme.subhead(context)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: PrimaryButton(label: 'Add Instructor', icon: CupertinoIcons.person_badge_plus, square: true, onPressed: () => _addPerson('instructor'))),
          const SizedBox(width: 12),
          Expanded(child: PrimaryButton(label: 'Add Student', icon: CupertinoIcons.person_add, square: true, onPressed: () => _addPerson('student'))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: PrimaryButton(label: 'Announcements', icon: CupertinoIcons.speaker_2_fill, square: true, onPressed: _manageAnnouncements)),
          const SizedBox(width: 12),
          Expanded(child: PrimaryButton(label: 'Converted Leads', icon: CupertinoIcons.person_2_square_stack, square: true, onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ConvertedLeadsScreen(auth: widget.auth),
          )))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: PrimaryButton(label: 'Communities', icon: CupertinoIcons.person_3_fill, square: true, onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => CommunitiesScreen(auth: widget.auth),
          )))),
          const SizedBox(width: 12),
          // A live host can only answer questions + watch live (no other access).
          Expanded(child: PrimaryButton(label: 'Add Live Host', icon: CupertinoIcons.dot_radiowaves_left_right, square: true, onPressed: () => _addPerson('live_host'))),
        ]),
        const SizedBox(height: 16),
        // Search across ALL people (name/email/phone/username/role).
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(color: Palette.of(context).card, border: Border.all(color: Palette.of(context).separator)),
          child: Row(children: [
            Icon(CupertinoIcons.search, size: 18, color: Palette.of(context).secondary),
            const SizedBox(width: 10),
            Expanded(child: TextField(
              onChanged: (v) => setState(() => _peopleQuery = v),
              style: AppleTheme.body(context),
              cursorColor: Palette.of(context).accent,
              decoration: InputDecoration(isDense: true, border: InputBorder.none,
                  hintText: 'Search people — name, email, phone…',
                  hintStyle: AppleTheme.body(context).copyWith(color: Palette.of(context).secondary)),
            )),
            if (_peopleQuery.isNotEmpty)
              HoverTap(onTap: () => setState(() => _peopleQuery = ''),
                  child: Icon(CupertinoIcons.clear_circled_solid, size: 18, color: Palette.of(context).secondary)),
          ]),
        ),
        const SizedBox(height: 18),
        if (_peopleQuery.trim().isNotEmpty) ...[
          // Flat search results across everyone, each with the ⋯ actions menu.
          ..._searchResults(_peopleQuery),
        ] else ...[
          if (others.isNotEmpty) ...[_peopleGroup('Admins', others, manage: true), const SizedBox(height: 18)],
          _peopleGroup('Instructors (${instructors.length})', instructors, manage: true),
          const SizedBox(height: 18),
          // A tappable list of courses — each opens its own students/batches page.
          ..._courseList(students),
        ],
      ],
    ));
  }

  // People-tab search: match across all users by name/email/phone/username/role.
  List<Widget> _searchResults(String query) {
    final q = query.trim().toLowerCase();
    final matches = _people.where((u) {
      final hay = [u['full_name'], u['email'], u['phone'], u['username'], u['role'], u['course_label']]
          .map((x) => (x ?? '').toString().toLowerCase())
          .join(' ');
      return hay.contains(q);
    }).toList();
    return [_peopleGroup('Results (${matches.length})', matches, manage: true)];
  }

  // Find the loaded course row for a course_label (case-insensitive), or null.
  Map<String, dynamic>? _courseForLabel(String label) {
    if (label.isEmpty) return null;
    for (final c in _courses) {
      if ((c['label']?.toString().toLowerCase() ?? '') == label.toLowerCase()) {
        return c as Map<String, dynamic>;
      }
    }
    return null;
  }

  // The Courses section of the People tab: one tappable card per course (by
  // course_label), redirecting to that course's students/batches page.
  List<Widget> _courseList(List<dynamic> students) {
    final byLabel = <String, List<dynamic>>{};
    for (final s in students) {
      final raw = s['course_label']?.toString().trim() ?? '';
      byLabel.putIfAbsent(raw, () => []).add(s);
    }
    // Students with no course_label are the "unassigned" list, shown separately
    // (a fully viewable + manageable group) rather than a dead course card.
    final unassigned = byLabel.remove('') ?? const <dynamic>[];
    final keys = byLabel.keys.toList()..sort((a, b) => a.compareTo(b));
    final out = <Widget>[const SectionHeader('Courses')];
    if (keys.isEmpty && unassigned.isEmpty) {
      out.add(AppleCard(square: true, child: Text('No students yet.', style: AppleTheme.footnote(context))));
      return out;
    }
    if (keys.isEmpty) {
      out.add(AppleCard(square: true, child: Text('No students assigned to a course yet.', style: AppleTheme.footnote(context))));
    }
    for (final c in keys) {
      final list = byLabel[c]!;
      final queue = list.where((s) => _batchOf(s) == null).length;
      final displayName = _courseDisplayName(c);
      final course = _courseForLabel(c);
      final orphan = c.isNotEmpty && course == null;
      final accent = c.isEmpty ? Palette.of(context).secondary : (orphan ? AppleColors.orange : Palette.of(context).accent);
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AppleCard(
          square: true,
          onTap: () {
            if (course != null) {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CourseBatchesScreen(auth: widget.auth, courseId: course['id'].toString(), title: course['title']?.toString() ?? displayName),
              )).then((_) => _load());
            } else if (c.isEmpty) {
              _toast('These students have no course assigned.');
            } else {
              _toast('No course exists for "$displayName" — create it in Courses, or fix the student\'s course label.');
            }
          },
          child: Row(children: [
            Container(
              width: 40, height: 40, alignment: Alignment.center,
              decoration: BoxDecoration(color: accent.withOpacity(0.14)),
              child: Icon(c.isEmpty ? CupertinoIcons.person_crop_circle_badge_xmark : (orphan ? CupertinoIcons.exclamationmark_triangle_fill : CupertinoIcons.book_fill), color: accent, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(displayName, style: AppleTheme.headline(context)),
              const SizedBox(height: 2),
              Text('${c.isEmpty ? '' : 'ID: $c · '}${list.length} student${list.length == 1 ? '' : 's'} · $queue in queue${orphan ? ' · no course' : ''}',
                  style: AppleTheme.footnote(context)),
            ])),
            Icon(CupertinoIcons.chevron_right, size: 18, color: Palette.of(context).secondary),
          ]),
        ),
      ));
    }
    if (unassigned.isNotEmpty) {
      out.add(const SizedBox(height: 18));
      out.add(_peopleGroup('Unassigned — no course (${unassigned.length})', unassigned, manage: true));
    }
    return out;
  }
  // Display name for a course_label = the matching course's title (course_title),
  // falling back to the raw ID slug when there's no course row for it.
  String _courseDisplayName(String courseLabel) {
    if (courseLabel.isEmpty) return 'No course';
    for (final c in _courses) {
      if ((c['label']?.toString().toLowerCase() ?? '') == courseLabel.toLowerCase()) {
        final t = c['title']?.toString().trim() ?? '';
        if (t.isNotEmpty) return t;
      }
    }
    return courseLabel;
  }
  // A user's batch code, treating missing/blank as unassigned (null).
  String? _batchOf(dynamic s) {
    final b = s['batch']?.toString().trim() ?? '';
    return b.isEmpty ? null : b;
  }

  // Show the original converted-lead record for a student (source, campaign,
  // program, score, UTM, ...) pulled from the database.
  Future<void> _showConvertedLead(String userId, String name) async {
    Map<String, dynamic>? lead;
    var found = false;
    String? err;
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/users/$userId/converted-lead');
      final data = ApiClient.decode(r);
      found = data['found'] == true;
      lead = (data['lead'] as Map?)?.cast<String, dynamic>();
    } on ApiException catch (e) {
      err = e.message;
    } catch (_) {
      err = 'Could not load lead detail';
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LeadDetailSheet(name: name, found: found, lead: lead, error: err),
    );
  }

  Widget _peopleGroup(String title, List<dynamic> people, {bool batch = false, bool manage = false}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(title),
      if (people.isEmpty)
        AppleCard(square: true, child: Text('None yet.', style: AppleTheme.footnote(context)))
      else
        AppleCard(square: true, 
          padding: EdgeInsets.zero,
          child: Column(children: List.generate(people.length, (i) {
            final u = people[i] as Map<String, dynamic>;
            return Column(children: [
              if (i > 0) Divider(height: 1, indent: 56, color: Palette.of(context).separator),
              ListTile(
                leading: Avatar(name: u['full_name']?.toString() ?? '?', size: 36),
                title: Text(u['full_name']?.toString() ?? '', style: AppleTheme.body(context)),
                subtitle: Text(u['email']?.toString() ?? '', style: AppleTheme.footnote(context)),
                onTap: () => _manageDevices(u['id'].toString(), u['full_name']?.toString() ?? 'User', u['email']?.toString() ?? ''),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (u['is_active'] == false) const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Icon(CupertinoIcons.nosign, color: AppleColors.red, size: 18),
                  ),
                  if (batch) ...[
                    HoverTap(
                      onTap: () => _showConvertedLead(u['id'].toString(), u['full_name']?.toString() ?? 'Student'),
                      child: Icon(CupertinoIcons.info_circle, color: Palette.of(context).secondary, size: 20),
                    ),
                    const SizedBox(width: 12),
                    HoverTap(
                      onTap: () => _setBatch(u['id'].toString(), u['full_name']?.toString() ?? 'Student', _batchOf(u)),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: Palette.of(context).accent.withOpacity(0.12), borderRadius: BorderRadius.zero),
                        child: Text(
                          _batchOf(u) ?? 'Set batch',
                          style: TextStyle(color: Palette.of(context).accent, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Icon(CupertinoIcons.device_phone_portrait, color: Palette.of(context).accent, size: 20),
                  if (batch || manage) ...[
                    const SizedBox(width: 12),
                    HoverTap(
                      onTap: () => _personActions(u),
                      child: Icon(CupertinoIcons.ellipsis, color: Palette.of(context).secondary, size: 20),
                    ),
                  ],
                ]),
              ),
            ]);
          })),
        ),
    ]);
  }

  // Per-person action hub. For a student this is the "do everything for one
  // student" menu — enroll in a course, set batch, issue a certificate, reset
  // the password, manage devices, view the originating lead, deactivate or
  // delete. Instructors/admins get just the account actions.
  Future<void> _personActions(Map<String, dynamic> u) async {
    final userId = u['id'].toString();
    final name = u['full_name']?.toString() ?? 'User';
    final email = u['email']?.toString() ?? '';
    final isStudent = u['role'] == 'student';
    final batch = _batchOf(u);
    final v = await showSquareMenu(context, title: name, items: [
      if (isStudent) const SquareMenuItem('Enroll in a course', value: 'enroll', icon: CupertinoIcons.book),
      if (isStudent) const SquareMenuItem('Set / change batch', value: 'batch', icon: CupertinoIcons.number),
      if (isStudent) const SquareMenuItem('Issue certificate', value: 'certificate', icon: CupertinoIcons.checkmark_seal),
      const SquareMenuItem('Set / change password', value: 'password', icon: CupertinoIcons.lock),
      const SquareMenuItem('Manage devices', value: 'devices', icon: CupertinoIcons.device_phone_portrait),
      if (isStudent) const SquareMenuItem('View converted lead', value: 'lead', icon: CupertinoIcons.info_circle),
      const SquareMenuItem('Deactivate (block sign-in)', value: 'deactivate', icon: CupertinoIcons.nosign),
      const SquareMenuItem('Delete permanently', value: 'delete', icon: CupertinoIcons.trash, destructive: true),
    ]);
    if (v == 'enroll') _enrollInCourse(name, email);
    if (v == 'batch') _setBatch(userId, name, batch);
    if (v == 'certificate') _issueCertificate(userId, name, u['course_label']?.toString() ?? '');
    if (v == 'password') _setPassword(userId, name);
    if (v == 'devices') _manageDevices(userId, name, email);
    if (v == 'lead') _showConvertedLead(userId, name);
    if (v == 'deactivate') _deactivatePerson(userId, name);
    if (v == 'delete') _deletePerson(userId, name);
  }

  // Enroll a student into a course the admin picks from the loaded list.
  Future<void> _enrollInCourse(String name, String email) async {
    if (email.isEmpty) { _toast('This student has no email on file'); return; }
    if (_courses.isEmpty) { _toast('No courses to enroll in'); return; }
    final items = _courses
        .map((c) => SquareMenuItem((c as Map)['title']?.toString() ?? 'Course',
            value: c['id'].toString(), icon: CupertinoIcons.book))
        .toList();
    final courseId = await showSquareMenu(context, title: 'Enroll $name in…', items: items);
    if (courseId == null) return;
    try {
      await widget.auth.apiPost('/api/v1/manage/courses/$courseId/enroll', {'email': email});
      _toast('Enrolled');
      _load();
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Could not enroll');
    }
  }

  // Issue a completion certificate to a single student. Uses the student's own
  // course (matched by course_label) when known, else asks which course.
  Future<void> _issueCertificate(String userId, String name, String courseLabel) async {
    var course = _courseForLabel(courseLabel);
    if (course == null) {
      if (_courses.isEmpty) { _toast('No courses to certify'); return; }
      final items = _courses
          .map((c) => SquareMenuItem((c as Map)['title']?.toString() ?? 'Course',
              value: c['id'].toString(), icon: CupertinoIcons.book))
          .toList();
      final picked = await showSquareMenu(context, title: 'Certificate for $name — which course?', items: items);
      if (picked == null) return;
      for (final c in _courses) {
        if ((c as Map)['id'].toString() == picked.toString()) { course = c.cast<String, dynamic>(); break; }
      }
      if (course == null) return;
    }
    final courseId = course['id'].toString();
    final title = course['title']?.toString() ?? 'this course';
    final yes = await showSquareConfirm(context,
        title: 'Issue certificate',
        message: 'Issue a "$title" completion certificate to $name?',
        confirmLabel: 'Issue');
    if (!yes) return;
    try {
      await widget.auth.apiPost('/api/v1/manage/courses/$courseId/certificates', {'user_ids': [userId]});
      _toast('Certificate issued');
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Could not issue certificate');
    }
  }

  // Admin sets/changes a user's login password (min 8 chars).
  Future<void> _setPassword(String userId, String name) async {
    final ctrl = TextEditingController();
    final ok = await showFormSheet(context, square: true, title: 'Set Password — $name',
        builder: (_) => [
          sheetField(ctrl, 'New password (min 8)', CupertinoIcons.lock),
          const SizedBox(height: 8),
          Text('The user signs in with this immediately.', style: AppleTheme.footnote(context)),
        ], onSubmit: () async {
      final pwd = ctrl.text.trim();
      if (pwd.length < 8) return 'Password must be at least 8 characters';
      try {
        await widget.auth.apiPost('/api/v1/manage/users/$userId/password', {'password': pwd});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) _toast('Password updated');
  }

  // Soft delete: mark inactive so the account can't log in (reversible).
  Future<void> _deactivatePerson(String userId, String name) async {
    final yes = await showSquareConfirm(context,
        title: 'Deactivate account',
        message: '$name will be blocked from signing in. Their record and data are kept and this can be undone.',
        confirmLabel: 'Deactivate', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/users/$userId');
      _toast('Account deactivated');
      _load();
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Could not deactivate');
    }
  }

  // Hard delete: permanently remove the account and cascade their data.
  Future<void> _deletePerson(String userId, String name) async {
    final yes = await showSquareConfirm(context,
        title: 'Delete permanently',
        message: 'Permanently delete $name and all their data? This cannot be undone.',
        confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/users/$userId/permanent');
      _toast('Account deleted');
      _load();
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Could not delete');
    }
  }

  // Assign a student to a batch by its code (leave blank to clear).
  Future<void> _setBatch(String userId, String name, String? current) async {
    String code = current ?? '';
    final ok = await showFormSheet(context, square: true, title: 'Set Batch — $name',
        builder: (_) => [
          _label(context, 'Batch code — leave blank to clear'),
          const SizedBox(height: 8),
          BatchCodeField(initial: current, onChanged: (v) => code = v),
        ],
        onSubmit: () async {
      try {
        // Empty string clears the batch (server treats blank as unassigned).
        await widget.auth.apiPost('/api/v1/manage/users/$userId/batch', {'batch': code.trim()});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      _toast('Batch updated');
      _load();
    }
  }

  // Broadcast an announcement to everyone, a batch, or one course's students.
  Future<void> _sendAnnouncement() async {
    // Courses for the "Course" audience (send to that course's students only).
    List<Map<String, dynamic>> courses = [];
    try {
      courses = (((ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/courses'))['courses']) as List?) ?? [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
    } catch (_) {}
    if (!mounted) return;
    final title = TextEditingController();
    final body = TextEditingController();
    String batchCode = '';
    int audience = 0; // 0=Everyone, 1=Batch, 2=Course
    bool preview = false;
    String? courseId = courses.isNotEmpty ? courses.first['id'].toString() : null;
    final p = Palette.of(context);
    final ok = await showFormSheet(context, square: true, full: true, title: 'Send Announcement', builder: (setS) => [
      sheetField(title, 'Title', CupertinoIcons.textformat),
      const SizedBox(height: 12),
      // Message supports Markdown, with a live editor + preview.
      ..._mdEditor(context, body: body, preview: preview, onPreview: (v) => setS(() => preview = v), refresh: () => setS(() {}),
          label: 'Message — Markdown supported (**bold**, - lists, # headings, > quote, `code`).'),
      const SizedBox(height: 14),
      Text('Audience', style: AppleTheme.footnote(context)),
      const SizedBox(height: 6),
      AppleSegmented(square: true, labels: const ['Everyone', 'Batch', 'Course'], selected: audience, onChanged: (i) => setS(() => audience = i)),
      if (audience == 1) ...[
        const SizedBox(height: 10),
        _label(context, 'Batch code — notifies students in this batch'),
        const SizedBox(height: 8),
        BatchCodeField(onChanged: (v) => batchCode = v),
      ],
      if (audience == 2) ...[
        const SizedBox(height: 10),
        _label(context, 'Course — only its enrolled students are notified'),
        const SizedBox(height: 6),
        if (courses.isEmpty)
          Text('No courses available.', style: AppleTheme.footnote(context))
        else
          ...courses.map((c) {
            final id = c['id'].toString();
            final on = id == courseId;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setS(() => courseId = id),
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(color: on ? p.accent.withOpacity(0.10) : p.card2, border: Border.all(color: on ? p.accent : p.separator)),
                child: Row(children: [
                  Icon(on ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle, size: 18, color: on ? p.accent : p.secondary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(c['title']?.toString() ?? 'Course', style: AppleTheme.body(context))),
                ]),
              ),
            );
          }),
      ],
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      final payload = <String, dynamic>{'title': title.text.trim(), 'body': body.text.trim()};
      if (audience == 0) {
        payload['audience'] = 'all';
      } else if (audience == 1) {
        if (batchCode.trim().isEmpty) return 'Enter the full batch code';
        payload['audience'] = 'batch';
        payload['batch_number'] = batchCode.trim();
      } else {
        if (courseId == null) return 'Pick a course';
        payload['course_id'] = courseId; // course-scoped: its students only
      }
      try {
        await widget.auth.apiPost('/api/v1/manage/announcements', payload);
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) _toast('Announcement sent');
  }

  // Announcements hub: compose new ones and remove existing ones.
  Future<void> _manageAnnouncements() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AnnouncementsSheet(auth: widget.auth, onNew: _sendAnnouncement),
    );
  }

  // Manage a student: devices + assign to a course.
  Future<void> _manageDevices(String userId, String name, String email) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DeviceSheet(auth: widget.auth, userId: userId, name: name, email: email),
    );
  }

  Future<void> _addPerson(String role) async {
    final email = TextEditingController();
    final username = TextEditingController();
    final name = TextEditingController();
    final pass = TextEditingController(text: 'onrol@aiee'); // default password
    final phone = TextEditingController();
    final courseLabel = TextEditingController();
    String batchCode = '';
    final occupation = TextEditingController();
    final location = TextEditingController();
    final linkedin = TextEditingController();
    final github = TextEditingController();
    final isStudent = role == 'student';
    final roleLabel = role == 'instructor' ? 'Instructor' : (role == 'live_host' ? 'Live Host' : 'Student');
    final ok = await showFormSheet(context, square: true, title: 'Add $roleLabel', builder: (_) => [
      sheetField(name, 'Full name', CupertinoIcons.person),
      const SizedBox(height: 10),
      sheetField(email, 'Email', CupertinoIcons.mail),
      const SizedBox(height: 10),
      sheetField(phone, 'Phone', CupertinoIcons.phone, keyboard: TextInputType.phone),
      const SizedBox(height: 10),
      sheetField(username, 'Username (optional — for sign-in)', CupertinoIcons.at),
      const SizedBox(height: 10),
      sheetField(pass, 'Password (default: onrol@aiee)', CupertinoIcons.lock),
      if (isStudent) ...[
        const SizedBox(height: 10),
        sheetField(courseLabel, 'Course label (e.g. aigeneralist)', CupertinoIcons.book),
        const SizedBox(height: 10),
        _label(context, 'Batch code (optional)'),
        const SizedBox(height: 8),
        BatchCodeField(onChanged: (v) => batchCode = v),
      ],
      const SizedBox(height: 10),
      sheetField(occupation, 'Occupation (optional)', CupertinoIcons.briefcase),
      const SizedBox(height: 10),
      sheetField(location, 'Location (optional)', CupertinoIcons.location),
      const SizedBox(height: 10),
      sheetField(linkedin, 'LinkedIn (optional)', CupertinoIcons.link),
      const SizedBox(height: 10),
      sheetField(github, 'GitHub (optional)', CupertinoIcons.link),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty || email.text.trim().isEmpty) return 'Name and email required';
      if (pass.text.trim().isNotEmpty && pass.text.trim().length < 8) return 'Password must be at least 8 characters';
      try {
        await widget.auth.apiPost('/api/v1/manage/users', {
          'full_name': name.text.trim(),
          'email': email.text.trim(),
          if (phone.text.trim().isNotEmpty) 'phone': phone.text.trim(),
          if (username.text.trim().isNotEmpty) 'username': username.text.trim(),
          'password': pass.text.trim(),
          'role': role,
          if (isStudent && courseLabel.text.trim().isNotEmpty) 'course_label': courseLabel.text.trim(),
          if (isStudent && batchCode.trim().isNotEmpty) 'batch': batchCode.trim(),
          if (occupation.text.trim().isNotEmpty) 'occupation': occupation.text.trim(),
          if (location.text.trim().isNotEmpty) 'location': location.text.trim(),
          if (linkedin.text.trim().isNotEmpty) 'linkedin': linkedin.text.trim(),
          if (github.text.trim().isNotEmpty) 'github': github.text.trim(),
        });
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      _toast('$roleLabel created');
      _load();
    }
  }

  Widget _newCourseButton() {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: _newCourse,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: p.accent,
          borderRadius: BorderRadius.zero,
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(CupertinoIcons.add, color: Colors.white, size: 18),
          SizedBox(width: 6),
          Text('New Course', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  double _hPad(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return (w > 712 ? ((w > 1180 ? w - 256 : w) - 700) / 2 : 18.0).clamp(18, 400);
  }

  Widget _consolePage() {
    final p = Palette.of(context);
    final roleLabel = widget.auth.user?.role == 'instructor' ? 'Mentor' : 'Admin';
    final hp = _hPad(context);
    return RefreshIndicator(
      color: p.accent,
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(hp, 18, hp, 40),
        children: [
          Text('$roleLabel Console', style: AppleTheme.largeTitle(context)),
          Text('Create and manage your courses', style: AppleTheme.subhead(context)),
          const SizedBox(height: 16),
          PrimaryButton(
            label: 'Video Store',
            icon: CupertinoIcons.film,
            square: true,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => VideoStoreScreen(auth: widget.auth))),
          ),
          const SizedBox(height: 20),
          if (_requests.isNotEmpty) ...[
            SectionHeader('Enrollment Requests (${_requests.length})'),
            ..._requests.map((r) => _requestCard(r as Map<String, dynamic>)),
            const SizedBox(height: 22),
          ],
          const SectionHeader('Your Courses'),
          if (_loading)
            const Padding(padding: EdgeInsets.symmetric(vertical: 30), child: Center(child: CupertinoActivityIndicator()))
          else if (_courses.isEmpty)
            AppleCard(square: true, 
              child: Column(children: [
                const Icon(CupertinoIcons.square_pencil, size: 34, color: AppleColors.blue),
                const SizedBox(height: 10),
                Text('No courses yet', style: AppleTheme.headline(context)),
                const SizedBox(height: 4),
                Text('Tap “New Course” to author your first one.', style: AppleTheme.footnote(context)),
              ]),
            )
          else
            ..._courses.map((c) => _courseRow(c as Map<String, dynamic>)),
        ],
      ),
    );
  }

  Widget _profilePage() => ProfileView(auth: widget.auth, onSignOut: _logout);

  Widget _courseRow(Map<String, dynamic> c) {
    final status = c['status']?.toString() ?? 'draft';
    final color = status == 'published' ? AppleColors.green : status == 'archived' ? Palette.of(context).secondary : AppleColors.orange;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppleCard(square: true, 
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SquareScope(child: CourseEditorScreen(auth: widget.auth, courseId: c['id'].toString(), title: c['title'].toString())),
        )).then((_) => _load()),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: AppleColors.blue.withOpacity(0.12), borderRadius: BorderRadius.zero),
            child: const Icon(CupertinoIcons.book_fill, color: AppleColors.blue, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c['title']?.toString() ?? 'Course', style: AppleTheme.headline(context)),
              const SizedBox(height: 2),
              Text(
                '${(c['label']?.toString().trim().isNotEmpty ?? false) ? 'ID: ${c['label']} · ' : ''}${c['enroll_type'] ?? ''} enrollment',
                style: AppleTheme.footnote(context),
              ),
            ]),
          ),
          // One-tap publish: students only see PUBLISHED courses in the catalog.
          // (Archived courses can't be published until restored.)
          Column(mainAxisSize: MainAxisSize.min, children: [
            CupertinoSwitch(
              value: status == 'published',
              activeTrackColor: AppleColors.green,
              onChanged: status == 'archived' ? null : (v) => _togglePublish(c['id'].toString(), v),
            ),
            Text(status == 'archived' ? 'Archived' : status == 'published' ? 'Visible' : 'Hidden',
                style: AppleTheme.footnote(context).copyWith(color: status == 'published' ? AppleColors.green : color)),
          ]),
          // Archive / delete actions — a proper boxed button (easy tap target).
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _courseMenu(c),
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: Palette.of(context).card2, border: Border.all(color: Palette.of(context).separator)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(CupertinoIcons.ellipsis, size: 17, color: Palette.of(context).label),
                const SizedBox(width: 6),
                Text('Options', style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700, color: Palette.of(context).label)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _requestCard(Map<String, dynamic> r) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppleCard(square: true, 
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: AppleColors.orange.withOpacity(0.14), borderRadius: BorderRadius.zero),
            child: const Icon(CupertinoIcons.person_badge_plus, color: AppleColors.orange, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r['student']?.toString() ?? r['email']?.toString() ?? 'Student', style: AppleTheme.headline(context)),
              Text('wants to join ${r['course'] ?? ''}', style: AppleTheme.footnote(context)),
            ]),
          ),
          GestureDetector(
            onTap: () => _decideRequest(r['id'].toString(), 'reject'),
            child: const Padding(padding: EdgeInsets.all(6), child: Icon(CupertinoIcons.xmark_circle_fill, color: AppleColors.red, size: 26)),
          ),
          GestureDetector(
            onTap: () => _decideRequest(r['id'].toString(), 'approve'),
            child: const Padding(padding: EdgeInsets.all(6), child: Icon(CupertinoIcons.checkmark_circle_fill, color: AppleColors.green, size: 28)),
          ),
        ]),
      ),
    );
  }

  // Pick a cover image and return it as a downscaled JPEG data URI (≤ ~900 KB),
  // or null if cancelled/failed. Same approach as profile avatars.
  Future<String?> _pickImageDataUri() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1280, maxHeight: 1280, imageQuality: 82);
      if (x == null) return null;
      final raw = await x.readAsBytes();
      if (raw.isEmpty) return null;
      Uint8List out;
      String mime;
      final decoded = img.decodeImage(raw);
      if (decoded != null) {
        // Cover ratio ~16:9, width 800.
        final resized = img.copyResize(decoded, width: decoded.width > 800 ? 800 : decoded.width);
        out = img.encodeJpg(resized, quality: 80);
        mime = 'image/jpeg';
      } else {
        out = raw;
        mime = x.mimeType ?? 'image/png';
      }
      if (out.lengthInBytes > 900000) {
        _toast('Image too large — try a smaller one.');
        return null;
      }
      return 'data:$mime;base64,${base64Encode(out)}';
    } catch (_) {
      _toast('Could not load that image.');
      return null;
    }
  }

  Future<void> _newCourse() async {
    // Fetch instructors for the assignment dropdown.
    List<dynamic> instructors = [];
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/instructors');
      instructors = (ApiClient.decode(r)['instructors'] as List?) ?? [];
    } catch (_) {}
    if (!mounted) return;
    if (instructors.isEmpty) {
      _toast('Create an instructor account first, then assign them.');
      return;
    }

    final title = TextEditingController();
    final courseId = TextEditingController();
    final desc = TextEditingController();
    final imageUrl = TextEditingController();
    String? imageData; // uploaded data URI (takes priority over the URL field)
    int enrollType = 0; // self, manual
    String instructorId = instructors.first['id'].toString();

    final created = await showFormSheet(
      context,
      title: 'New Course',
      builder: (setS) => [
        sheetField(courseId, 'Course ID — unique (e.g. aiarchitect)', CupertinoIcons.tag),
        const SizedBox(height: 10),
        sheetField(title, 'Display title (shown to students)', CupertinoIcons.textformat),
        const SizedBox(height: 10),
        sheetField(desc, 'Description', CupertinoIcons.text_alignleft),
        const SizedBox(height: 16),
        _label(context, 'Cover image'),
        const SizedBox(height: 6),
        _CourseImagePicker(
          dataUri: imageData,
          urlController: imageUrl,
          onUpload: () async {
            final d = await _pickImageDataUri();
            if (d != null) setS(() => imageData = d);
          },
          onClear: () => setS(() => imageData = null),
          onUrlChanged: () => setS(() {}),
        ),
        const SizedBox(height: 16),
        _label(context, 'Assign instructor'),
        const SizedBox(height: 6),
        _InstructorDropdown(
          instructors: instructors,
          selectedId: instructorId,
          onChanged: (id) => setS(() => instructorId = id),
        ),
        const SizedBox(height: 16),
        _label(context, 'Enrollment'),
        const SizedBox(height: 6),
        AppleSegmented(square: true, labels: const ['Self-enroll', 'Manual'], selected: enrollType, onChanged: (i) => setS(() => enrollType = i)),
      ],
      onSubmit: () async {
        if (title.text.trim().isEmpty) return 'Display title is required';
        try {
          final image = imageData ?? (imageUrl.text.trim().isNotEmpty ? imageUrl.text.trim() : null);
          await widget.auth.apiPost('/api/v1/manage/courses', {
            'title': title.text.trim(),
            if (courseId.text.trim().isNotEmpty) 'label': courseId.text.trim(),
            'description': desc.text.trim(),
            'enroll_type': enrollType == 0 ? 'self' : 'manual',
            'instructor_id': instructorId,
            if (image != null) 'image_url': image,
          });
          return null;
        } on ApiException catch (e) {
          return e.message;
        }
      },
    );
    if (created == true) {
      _toast('Course created');
      _load();
    }
  }
}

Widget _label(BuildContext context, String t) =>
    Align(alignment: Alignment.centerLeft, child: Text(t, style: AppleTheme.footnote(context)));

// A tall, roomy Markdown editor shared by Add & Edit Course Material. On a
// wide sheet it's a LIVE split view — raw Markdown on the left, rendered
// output on the right, updating as you type. On narrow screens it falls back
// to a Write ⇄ Preview toggle. [refresh] rebuilds so the preview stays live.
List<Widget> _mdEditor(BuildContext context, {required TextEditingController body, required bool preview, required void Function(bool) onPreview, required void Function() refresh, String? label}) {
  final size = MediaQuery.of(context).size;
  final h = (size.height * 0.62).clamp(360.0, 1100.0);
  final split = size.width > 720;
  final p = Palette.of(context);

  Widget editor() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: p.card2, border: Border.all(color: p.separator)),
        child: TextField(
          controller: body,
          expands: true,
          maxLines: null,
          minLines: null,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          onChanged: split ? (_) => refresh() : null, // keep the live preview in sync
          style: TextStyle(color: p.label, fontSize: 15, height: 1.5),
          decoration: InputDecoration(border: InputBorder.none, isDense: true, hintText: 'Paste or write Markdown…', hintStyle: TextStyle(color: p.secondary)),
        ),
      );

  Widget rendered() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: p.card2, border: Border.all(color: p.separator)),
        child: SingleChildScrollView(
          child: MarkdownView(
            text: body.text,
            textColor: p.label,
            mutedColor: p.secondary,
            accent: p.accent,
            borderColor: p.separator,
            dark: p.dark,
            emptyLabel: 'Nothing to preview yet — write some Markdown.',
          ),
        ),
      );

  Widget paneLabel(String s) => Padding(padding: const EdgeInsets.only(left: 2, bottom: 4), child: Text(s, style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700, color: p.secondary)));

  return [
    _label(context, label ?? 'Content — Markdown supported (# headings, **bold**, - lists, > quote, `code`). Paste Markdown here.'),
    const SizedBox(height: 8),
    if (split) ...[
      Row(children: [
        Expanded(child: paneLabel('Write')),
        const SizedBox(width: 12),
        Expanded(child: paneLabel('Live preview')),
      ]),
      SizedBox(
        height: h,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: editor()),
          const SizedBox(width: 12),
          Expanded(child: rendered()),
        ]),
      ),
    ] else ...[
      AppleSegmented(square: true, labels: const ['Write', 'Preview'], selected: preview ? 1 : 0, onChanged: (i) => onPreview(i == 1)),
      const SizedBox(height: 8),
      SizedBox(height: h, child: preview ? rendered() : editor()),
    ],
  ];
}


/// Issue certificates to learners — pick individuals, a whole batch, or everyone
/// enrolled. Shows who already holds one. Re-issuing is a no-op (skipped).
class _IssueCertificates extends StatefulWidget {
  const _IssueCertificates({required this.auth, required this.courseId, required this.title});
  final AuthService auth;
  final String courseId;
  final String title;
  @override
  State<_IssueCertificates> createState() => _IssueCertificatesState();
}

class _IssueCertificatesState extends State<_IssueCertificates> {
  List<dynamic> _students = [];
  final Set<String> _issued = {}; // user_ids who already have a certificate
  final Set<String> _selected = {};
  bool _loading = true;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await widget.auth.apiGet('/api/v1/manage/courses/${widget.courseId}/students');
      _students = (ApiClient.decode(s)['students'] as List?) ?? [];
      final c = await widget.auth.apiGet('/api/v1/manage/courses/${widget.courseId}/certificates');
      _issued
        ..clear()
        ..addAll(((ApiClient.decode(c)['certificates'] as List?) ?? []).map((e) => (e as Map)['user_id'].toString()));
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _issue(Map<String, dynamic> body, String what) async {
    setState(() => _working = true);
    try {
      final r = await widget.auth.apiPost('/api/v1/manage/courses/${widget.courseId}/certificates', body);
      final n = (ApiClient.decode(r)['issued'] ?? 0);
      _selected.clear();
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Issued $n certificate${n == 1 ? '' : 's'} ($what)'), behavior: SnackBarBehavior.floating));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not issue')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _issueByBatch() async {
    String code = '';
    final ok = await showFormSheet(context, square: true, title: 'Issue by batch',
        builder: (_) => [
          _label(context, 'Batch code'),
          const SizedBox(height: 8),
          BatchCodeField(onChanged: (v) => code = v),
        ],
        onSubmit: () async {
      if (code.trim().isEmpty) return 'Enter the full batch code';
      return null;
    });
    if (ok == true && code.trim().isNotEmpty) {
      _issue({'batch': code.trim()}, 'batch ${code.trim()}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final w = MediaQuery.of(context).size.width;
    final hp = (w > 760 ? (w - 720) / 2 : 14.0).clamp(14, 400).toDouble();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(icon: const Icon(CupertinoIcons.chevron_left), onPressed: () => Navigator.pop(context)),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Issue Certificates', style: AppleTheme.headline(context)),
          Text(widget.title, style: AppleTheme.footnote(context)),
        ]),
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(hp, 12, hp, 24),
              children: [
                Row(children: [
                  Expanded(child: PrimaryButton(label: 'Whole course', icon: CupertinoIcons.group, square: true, busy: _working, onPressed: () => _issue({'all': true}, 'all enrolled'))),
                  const SizedBox(width: 10),
                  Expanded(child: PrimaryButton(label: 'By batch', icon: CupertinoIcons.number_square, square: true, onPressed: _issueByBatch)),
                ]),
                const SizedBox(height: 18),
                Row(children: [
                  Expanded(child: SectionHeader('Students (${_students.length})')),
                  if (_selected.isNotEmpty)
                    GestureDetector(
                      onTap: () => _issue({'user_ids': _selected.toList()}, '${_selected.length} selected'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.zero),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(CupertinoIcons.rosette, size: 15, color: Colors.white),
                          const SizedBox(width: 6),
                          Text('Issue ${_selected.length}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                        ]),
                      ),
                    ),
                ]),
                const SizedBox(height: 4),
                if (_students.isEmpty)
                  AppleCard(square: true, child: Text('No students enrolled yet.', style: AppleTheme.footnote(context)))
                else
                  ..._students.map((s) => _studentRow(s as Map<String, dynamic>)),
              ],
            ),
    );
  }

  Widget _studentRow(Map<String, dynamic> s) {
    final id = s['id'].toString();
    final has = _issued.contains(id);
    final sel = _selected.contains(id);
    final batch = s['batch'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppleCard(square: true, 
        onTap: has ? null : () => setState(() => sel ? _selected.remove(id) : _selected.add(id)),
        child: Row(children: [
          Icon(
            has ? CupertinoIcons.checkmark_seal_fill : (sel ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle),
            color: has ? AppleColors.green : (sel ? Palette.of(context).accent : Palette.of(context).secondary), size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s['name']?.toString() ?? 'Student', style: AppleTheme.headline(context)),
              Text([
                if (batch != null) 'Batch $batch',
                '${s['percent'] ?? 0}% complete',
              ].join(' · '), style: AppleTheme.footnote(context)),
            ]),
          ),
          if (has)
            GestureDetector(
              onTap: () async {
                await widget.auth.apiDelete('/api/v1/manage/courses/${widget.courseId}/certificates/$id');
                _load();
              },
              child: Text('Revoke', style: AppleTheme.footnote(context).copyWith(color: AppleColors.red, fontWeight: FontWeight.w600)),
            )
          else
            Text(sel ? 'Selected' : 'Tap to select', style: AppleTheme.footnote(context)),
        ]),
      ),
    );
  }
}

/// Proper quiz builder: list a quiz's questions (with the correct answer
/// marked), add questions (MCQ with real options + pick-the-correct, true/false,
/// short answer), and delete questions.
class _QuizBuilder extends StatefulWidget {
  const _QuizBuilder({required this.auth, required this.assessmentId, required this.title, this.isQuiz = true});
  final AuthService auth;
  final String assessmentId;
  final String title;
  final bool isQuiz;
  @override
  State<_QuizBuilder> createState() => _QuizBuilderState();
}

class _QuizBuilderState extends State<_QuizBuilder> {
  List<dynamic> _questions = [];
  bool _loading = true;
  String? _error; // why the list is empty, if loading failed

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/assessments/${widget.assessmentId}/questions');
      final list = (ApiClient.decode(r)['questions'] as List?) ?? [];
      if (!mounted) return;
      setState(() { _questions = list; _loading = false; _error = null; });
    } on ApiException catch (e) {
      // Surface the reason instead of silently showing an empty list — an admin
      // who just added questions needs to know if the reload failed (auth, etc).
      if (mounted) setState(() { _loading = false; _error = e.message; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = "Couldn't load questions — check your connection and retry."; });
    }
  }

  Future<void> _delete(String id) async {
    try {
      await widget.auth.apiDelete('/api/v1/manage/questions/$id');
      _load();
    } catch (_) {}
  }

  // Draft questions with AI from a topic/source — they're inserted for review.
  Future<void> _generate() async {
    final topic = TextEditingController();
    final count = TextEditingController(text: '5');
    int diff = 1; // easy / medium / hard
    int kind = 0; // mixed / mcq / short / essay
    const diffs = ['easy', 'intermediate', 'hard'];
    const kindVals = ['a sensible mix of mcq, truefalse, short, and essay', 'mcq', 'short', 'essay'];
    final ok = await showFormSheet(context, square: true, title: 'Generate with AI', builder: (setS) => [
      Text('Describe the topic or paste source material — AI drafts questions you can edit or delete.', style: AppleTheme.footnote(context)),
      const SizedBox(height: 10),
      sheetField(topic, 'Topic or source material', CupertinoIcons.text_quote),
      const SizedBox(height: 10),
      sheetField(count, 'How many (1–20)', CupertinoIcons.number, keyboard: TextInputType.number),
      const SizedBox(height: 12),
      _label(context, 'Difficulty'),
      const SizedBox(height: 6),
      AppleSegmented(square: true, labels: const ['Easy', 'Medium', 'Hard'], selected: diff, onChanged: (i) => setS(() => diff = i)),
      const SizedBox(height: 12),
      _label(context, 'Question types'),
      const SizedBox(height: 6),
      AppleSegmented(square: true, labels: const ['Mixed', 'MCQ', 'Short', 'Essay'], selected: kind, onChanged: (i) => setS(() => kind = i)),
    ], onSubmit: () async {
      if (topic.text.trim().isEmpty) return 'Enter a topic';
      try {
        await widget.auth.apiPost('/api/v1/manage/assessments/${widget.assessmentId}/generate', {
          'topic': topic.text.trim(),
          'count': int.tryParse(count.text.trim()) ?? 5,
          'difficulty': diffs[diff],
          'types': kindVals[kind],
        });
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) _load();
  }

  // Add a new question, or edit an existing one when [edit] is passed.
  Future<void> _questionForm([Map<String, dynamic>? edit]) async {
    const types = ['mcq', 'multi', 'truefalse', 'short', 'fill', 'numeric', 'essay', 'upload'];
    const typeLabels = ['Multiple choice', 'Multiple response', 'True / False', 'Short answer', 'Fill in the blank', 'Numerical', 'Essay', 'Upload file'];
    final existing = ((edit?['options'] as List?) ?? const []).map((e) => e.toString()).toList();
    final correctStr = edit?['correct']?.toString() ?? '';
    int type = edit == null ? 0 : types.indexOf(edit['type']?.toString() ?? 'mcq');
    if (type < 0) type = 0;
    final prompt = TextEditingController(text: edit?['prompt']?.toString() ?? '');
    final points = TextEditingController(text: edit == null ? '1' : '${edit['points'] ?? 1}');
    final opts = <TextEditingController>[];
    int correctIdx = 0; // mcq + truefalse
    final correctSet = <int>{}; // multi
    final tk0 = types[type];
    if ((tk0 == 'mcq' || tk0 == 'multi') && existing.isNotEmpty) {
      for (final o in existing) {
        opts.add(TextEditingController(text: o));
      }
      if (tk0 == 'mcq') {
        final ci = existing.indexOf(correctStr);
        correctIdx = ci >= 0 ? ci : 0;
      } else {
        try {
          final list = (jsonDecode(correctStr) as List).map((e) => e.toString()).toList();
          for (var i = 0; i < existing.length; i++) {
            if (list.contains(existing[i])) correctSet.add(i);
          }
        } catch (_) {}
      }
    } else if (tk0 == 'truefalse') {
      correctIdx = correctStr == 'false' ? 1 : 0;
    }
    while (opts.length < 2) {
      opts.add(TextEditingController());
    }
    final shortAns = TextEditingController(text: (tk0 == 'short' || tk0 == 'fill' || tk0 == 'numeric') ? correctStr : '');

    final ok = await showFormSheet(context, square: true, big: true, title: edit == null ? 'Add Question' : 'Edit Question', builder: (setS) {
      final p = Palette.of(context);
      final tkey = types[type];
      final rows = <Widget>[
        sheetField(prompt, 'Question prompt', CupertinoIcons.text_quote),
        const SizedBox(height: 10),
        _label(context, 'Question type'),
        const SizedBox(height: 6),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () async {
            final picked = await showDialog<int>(
              context: context,
              builder: (dctx) {
                final dp = Palette.of(dctx);
                return Dialog(
                  backgroundColor: dp.card,
                  insetPadding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), child: Text('Select question type', style: AppleTheme.headline(dctx))),
                      for (var i = 0; i < typeLabels.length; i++)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.of(dctx).pop(i),
                          child: Container(
                            color: i == type ? dp.accent.withOpacity(0.12) : null,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                            child: Row(children: [
                              Icon(i == type ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle, size: 20, color: i == type ? dp.accent : dp.secondary),
                              const SizedBox(width: 12),
                              Expanded(child: Text(typeLabels[i], style: AppleTheme.body(dctx))),
                            ]),
                          ),
                        ),
                      const SizedBox(height: 8),
                    ]),
                  ),
                );
              },
            );
            if (picked != null) {
              setS(() {
                type = picked;
                correctIdx = 0;
                correctSet.clear();
              });
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(color: p.card2, border: Border.all(color: p.separator)),
            child: Row(children: [
              Expanded(child: Text(typeLabels[type], style: AppleTheme.body(context).copyWith(fontWeight: FontWeight.w700))),
              Icon(CupertinoIcons.chevron_up_chevron_down, size: 16, color: p.secondary),
            ]),
          ),
        ),
        const SizedBox(height: 14),
      ];
      final isMulti = tkey == 'multi';
      if (tkey == 'mcq' || isMulti) {
        rows.add(_label(context, isMulti ? 'Options — tick EVERY correct answer' : 'Options — tap the circle to mark the correct one'));
        rows.add(const SizedBox(height: 6));
        for (var i = 0; i < opts.length; i++) {
          final sel = isMulti ? correctSet.contains(i) : correctIdx == i;
          rows.add(Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              GestureDetector(
                onTap: () => setS(() {
                  if (isMulti) {
                    sel ? correctSet.remove(i) : correctSet.add(i);
                  } else {
                    correctIdx = i;
                  }
                }),
                child: Icon(
                    sel
                        ? (isMulti ? CupertinoIcons.checkmark_square_fill : CupertinoIcons.checkmark_circle_fill)
                        : (isMulti ? CupertinoIcons.square : CupertinoIcons.circle),
                    color: sel ? AppleColors.green : Palette.of(context).secondary, size: 24),
              ),
              const SizedBox(width: 10),
              Expanded(child: sheetField(opts[i], 'Option ${i + 1}', CupertinoIcons.circle_grid_hex)),
              if (opts.length > 2) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => setS(() {
                    opts.removeAt(i);
                    correctSet.remove(i);
                    if (correctIdx >= opts.length) correctIdx = opts.length - 1;
                  }),
                  child: const Icon(CupertinoIcons.minus_circle, size: 20, color: AppleColors.red),
                ),
              ],
            ]),
          ));
        }
        rows.add(Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            onTap: () => setS(() => opts.add(TextEditingController())),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(CupertinoIcons.add_circled, size: 18, color: Palette.of(context).accent),
              const SizedBox(width: 4),
              Text('Add option', style: AppleTheme.footnote(context).copyWith(color: Palette.of(context).accent, fontWeight: FontWeight.w600)),
            ]),
          ),
        ));
      } else if (tkey == 'truefalse') {
        rows.add(_label(context, 'Correct answer'));
        rows.add(const SizedBox(height: 6));
        rows.add(AppleSegmented(square: true, labels: const ['True', 'False'], selected: correctIdx, onChanged: (i) => setS(() => correctIdx = i)));
      } else if (tkey == 'short') {
        rows.add(sheetField(shortAns, 'Correct answer', CupertinoIcons.checkmark_alt_circle));
      } else if (tkey == 'fill') {
        rows.add(sheetField(shortAns, 'Accepted answer(s) — separate alternatives with |', CupertinoIcons.text_cursor));
      } else if (tkey == 'numeric') {
        rows.add(sheetField(shortAns, 'Correct number', CupertinoIcons.number, keyboard: const TextInputType.numberWithOptions(decimal: true, signed: true)));
      } else if (tkey == 'essay') {
        rows.add(_label(context, 'Long answer — students write a response and you grade it manually. No answer key needed.'));
      } else {
        rows.add(_label(context, 'Upload — students upload a file as their answer; you grade it manually.'));
      }
      rows.add(const SizedBox(height: 12));
      rows.add(sheetField(points, 'Points', CupertinoIcons.number, keyboard: TextInputType.number));
      return rows;
    }, onSubmit: () async {
      if (prompt.text.trim().isEmpty) return 'Prompt required';
      final tkey = types[type];
      List<String> options;
      String correct;
      if (tkey == 'mcq') {
        options = opts.map((c) => c.text.trim()).where((s) => s.isNotEmpty).toList();
        if (options.length < 2) return 'Add at least two options';
        if (correctIdx >= options.length) return 'Pick the correct option';
        correct = options[correctIdx];
      } else if (tkey == 'multi') {
        options = opts.map((c) => c.text.trim()).where((s) => s.isNotEmpty).toList();
        if (options.length < 2) return 'Add at least two options';
        final correctOpts = <String>[];
        for (var i = 0; i < opts.length; i++) {
          if (correctSet.contains(i) && opts[i].text.trim().isNotEmpty) correctOpts.add(opts[i].text.trim());
        }
        if (correctOpts.isEmpty) return 'Tick at least one correct answer';
        correct = jsonEncode(correctOpts);
      } else if (tkey == 'truefalse') {
        options = ['true', 'false'];
        correct = correctIdx == 0 ? 'true' : 'false';
      } else if (tkey == 'short' || tkey == 'fill') {
        options = [];
        correct = shortAns.text.trim();
        if (correct.isEmpty) return 'Enter the correct answer';
      } else if (tkey == 'numeric') {
        options = [];
        correct = shortAns.text.trim();
        if (double.tryParse(correct) == null) return 'Enter a valid number';
      } else {
        options = [];
        correct = '';
      }
      final payload = <String, dynamic>{
        'prompt': prompt.text.trim(),
        'type': tkey,
        'options': options,
        'correct': correct,
        'points': double.tryParse(points.text.trim()) ?? 1,
      };
      try {
        if (edit == null) {
          await widget.auth.apiPost('/api/v1/manage/assessments/${widget.assessmentId}/questions', payload);
        } else {
          await widget.auth.apiPatch('/api/v1/manage/questions/${edit['id']}', payload);
        }
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final w = MediaQuery.of(context).size.width;
    final hp = (w > 760 ? (w - 720) / 2 : 14.0).clamp(14, 400).toDouble();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(icon: const Icon(CupertinoIcons.chevron_left), onPressed: () => Navigator.pop(context)),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.isQuiz ? 'Quiz builder' : 'Assignment questions', style: AppleTheme.headline(context)),
          Text(widget.title, style: AppleTheme.footnote(context)),
        ]),
        actions: [
          IconButton(
            tooltip: 'Generate with AI',
            icon: Icon(CupertinoIcons.sparkles, color: p.accent),
            onPressed: _generate,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: p.accent,
        onPressed: () => _questionForm(),
        icon: const Icon(CupertinoIcons.add, color: Colors.white),
        label: const Text('Add question', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(hp, 12, hp, 96),
                children: [
                  if (_error != null)
                    AppleCard(square: true, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        const Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 18, color: AppleColors.red),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_error!, style: AppleTheme.footnote(context).copyWith(color: AppleColors.red))),
                      ]),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: GestureDetector(
                          onTap: _load,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(color: Palette.of(context).accent.withOpacity(0.12), borderRadius: BorderRadius.zero),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(CupertinoIcons.refresh, size: 15, color: Palette.of(context).accent),
                              const SizedBox(width: 4),
                              Text('Try again', style: TextStyle(color: Palette.of(context).accent, fontSize: 13, fontWeight: FontWeight.w600)),
                            ]),
                          ),
                        ),
                      ),
                    ]))
                  else if (_questions.isEmpty)
                    AppleCard(square: true, child: Text('No questions yet. Tap “Add question” to build this ${widget.isQuiz ? 'quiz' : 'assignment'}.', style: AppleTheme.footnote(context)))
                  else
                    ..._questions.asMap().entries.map((e) => _questionCard(e.key + 1, e.value as Map<String, dynamic>)),
                ],
              ),
            ),
    );
  }

  Widget _questionCard(int n, Map<String, dynamic> q) {
    final options = (q['options'] as List?) ?? [];
    final type = q['type']?.toString() ?? 'mcq';
    final correct = q['correct']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppleCard(square: true, 
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text('$n. ${q['prompt'] ?? ''}', style: AppleTheme.body(context).copyWith(fontWeight: FontWeight.w700))),
            Text('${q['points'] ?? 1} pt', style: AppleTheme.footnote(context)),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () => _questionForm(q),
              child: Icon(CupertinoIcons.pencil, size: 18, color: Palette.of(context).secondary),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () => _delete(q['id'].toString()),
              child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red),
            ),
          ]),
          const SizedBox(height: 8),
          if (type == 'short')
            Row(children: [
              const Icon(CupertinoIcons.checkmark_alt_circle_fill, size: 16, color: AppleColors.green),
              const SizedBox(width: 6),
              Expanded(child: Text('Answer: $correct', style: AppleTheme.footnote(context))),
            ])
          else if (type == 'essay')
            Row(children: [
              const Icon(CupertinoIcons.text_alignleft, size: 16, color: AppleColors.blue),
              const SizedBox(width: 6),
              Expanded(child: Text('Long answer — graded manually', style: AppleTheme.footnote(context))),
            ])
          else
            ...options.map((o) {
              final isCorrect = o.toString() == correct;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Icon(isCorrect ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                      size: 16, color: isCorrect ? AppleColors.green : Palette.of(context).secondary),
                  const SizedBox(width: 8),
                  Expanded(child: Text(o.toString(),
                      style: AppleTheme.body(context).copyWith(fontSize: 14,
                          color: isCorrect ? AppleColors.green : Palette.of(context).label,
                          fontWeight: isCorrect ? FontWeight.w700 : FontWeight.w400))),
                ]),
              );
            }),
        ]),
      ),
    );
  }
}

/// Course cover image control: a preview + Upload button + paste-URL field.
/// Upload wins over the URL when both are set.
class _CourseImagePicker extends StatelessWidget {
  const _CourseImagePicker({
    required this.dataUri,
    required this.urlController,
    required this.onUpload,
    required this.onClear,
    this.onUrlChanged,
  });
  final String? dataUri;
  final TextEditingController urlController;
  final VoidCallback onUpload;
  final VoidCallback onClear;
  final VoidCallback? onUrlChanged;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final preview = dataUri ?? (urlController.text.trim().startsWith('http') ? urlController.text.trim() : null);
    Widget? pic;
    if (preview != null) {
      if (preview.startsWith('data:')) {
        try {
          pic = Image.memory(base64Decode(preview.substring(preview.indexOf(',') + 1)),
              height: 130, width: double.infinity, fit: BoxFit.cover);
        } catch (_) {}
      } else {
        pic = Image.network(preview, height: 130, width: double.infinity, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox());
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (pic != null) ...[
        ClipRRect(borderRadius: BorderRadius.zero, child: pic),
        const SizedBox(height: 8),
      ],
      Row(children: [
        Expanded(child: PrimaryButton(
          label: dataUri == null ? 'Upload image' : 'Change image',
          icon: CupertinoIcons.photo, square: true, onPressed: onUpload)),
        if (dataUri != null) ...[
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onClear,
            child: Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.zero),
              child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 8),
      CupertinoTextField(
        controller: urlController,
        placeholder: 'or paste an image URL',
        padding: const EdgeInsets.all(12),
        style: TextStyle(color: p.label, fontSize: 14),
        onChanged: (_) => onUrlChanged?.call(),
        decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.zero),
      ),
    ]);
  }
}

/// Friendly local time from an ISO-8601 string, e.g. "Jun 11, 5:30 PM".
String _fmtTime(String? iso) {
  if (iso == null || iso.isEmpty) return 'Time TBD';
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return iso;
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final ampm = dt.hour < 12 ? 'AM' : 'PM';
  final m = dt.minute.toString().padLeft(2, '0');
  return '${months[dt.month - 1]} ${dt.day}, $h:$m $ampm';
}

/// Tappable date+time field (date picker → time picker).
class _DateTimeRow extends StatelessWidget {
  const _DateTimeRow({required this.value, required this.onPick});
  final DateTime value;
  final ValueChanged<DateTime> onPick;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: () async {
        final defaultFirst = DateTime.now().subtract(const Duration(days: 1));
        final d = await showDatePicker(
          context: context,
          initialDate: value,
          // Allow editing a session already in the past without tripping the
          // picker's initialDate >= firstDate assertion.
          firstDate: value.isBefore(defaultFirst) ? DateTime(value.year, value.month, value.day) : defaultFirst,
          lastDate: DateTime.now().add(const Duration(days: 365)),
        );
        if (d == null) return;
        final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(value));
        if (t == null) return;
        onPick(DateTime(d.year, d.month, d.day, t.hour, t.minute));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.zero),
        child: Row(children: [
          Icon(CupertinoIcons.calendar, size: 19, color: p.secondary),
          const SizedBox(width: 12),
          Expanded(child: Text(_fmtTime(value.toIso8601String()), style: AppleTheme.body(context))),
          Icon(CupertinoIcons.chevron_right, size: 16, color: p.secondary),
        ]),
      ),
    );
  }
}

/// Apple-style instructor picker — a tappable field that opens a Cupertino
/// selection of instructors.
class _InstructorDropdown extends StatelessWidget {
  const _InstructorDropdown({required this.instructors, required this.selectedId, required this.onChanged});
  final List<dynamic> instructors;
  final String selectedId;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final selected = instructors.firstWhere((i) => i['id'].toString() == selectedId, orElse: () => instructors.first);
    return GestureDetector(
      onTap: () => _pick(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.zero),
        child: Row(children: [
          Icon(CupertinoIcons.person_crop_circle, size: 19, color: p.secondary),
          const SizedBox(width: 12),
          Expanded(child: Text(selected['full_name']?.toString() ?? 'Select', style: AppleTheme.body(context))),
          Icon(CupertinoIcons.chevron_up_chevron_down, size: 17, color: p.secondary),
        ]),
      ),
    );
  }

  void _pick(BuildContext context) {
    final p = Palette.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.zero),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.all(16), child: Text('Assign Instructor', style: AppleTheme.headline(context))),
          ...instructors.map((i) {
            final on = i['id'].toString() == selectedId;
            return ListTile(
              title: Text(i['full_name']?.toString() ?? '', style: AppleTheme.body(context)),
              subtitle: Text(i['email']?.toString() ?? '', style: AppleTheme.footnote(context)),
              trailing: on ? Icon(CupertinoIcons.checkmark_alt, color: p.accent) : null,
              onTap: () {
                onChanged(i['id'].toString());
                Navigator.pop(context);
              },
            );
          }),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

/// Course editor — modules, lessons, publish, enroll.
class CourseEditorScreen extends StatefulWidget {
  const CourseEditorScreen({super.key, required this.auth, required this.courseId, required this.title});
  final AuthService auth;
  final String courseId;
  final String title;

  @override
  State<CourseEditorScreen> createState() => _CourseEditorScreenState();
}

class _CourseEditorScreenState extends State<CourseEditorScreen> {
  Map<String, dynamic>? _course;
  List<dynamic> _sessions = [];
  List<dynamic> _students = [];
  List<dynamic> _assessments = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/courses/${widget.courseId}');
      _course = ApiClient.decode(r);
      final s = await widget.auth.apiGet('/api/v1/manage/courses/${widget.courseId}/sessions');
      _sessions = (ApiClient.decode(s)['sessions'] as List?) ?? [];
      final st = await widget.auth.apiGet('/api/v1/manage/courses/${widget.courseId}/students');
      _students = (ApiClient.decode(st)['students'] as List?) ?? [];
      final a = await widget.auth.apiGet('/api/v1/manage/courses/${widget.courseId}/assessments');
      _assessments = (ApiClient.decode(a)['assessments'] as List?) ?? [];
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  static const _admModes = ['self', 'manual', 'closed'];
  static const _admLabels = ['Open', 'Approval', 'Closed'];
  static const _admDesc = [
    'Anyone can enroll instantly.',
    'Students request; you approve.',
    'Admin-only — you enroll students.',
  ];

  Future<void> _setAdmission(String mode) async {
    try {
      await widget.auth.apiPatch('/api/v1/manage/courses/${widget.courseId}', {'enroll_type': mode});
      _toast('Admission updated');
      _load();
    } catch (_) {
      _toast('Could not update admission');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final status = _course?['status']?.toString() ?? 'draft';
    final published = status == 'published';
    final modules = (_course?['modules'] as List?) ?? [];
    final enrollType = _course?['enroll_type']?.toString() ?? 'manual';
    final admIndex = _admModes.indexOf(enrollType) < 0 ? 1 : _admModes.indexOf(enrollType);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: p.bg.withOpacity(0.9),
        scrolledUnderElevation: 0,
        elevation: 0,
        leading: IconButton(icon: const Icon(CupertinoIcons.chevron_left), onPressed: () => Navigator.pop(context)),
        title: Text(widget.title, style: AppleTheme.headline(context)),
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                // Status + publish toggle.
                AppleCard(square: true, 
                  child: Row(children: [
                    Icon(published ? CupertinoIcons.checkmark_seal_fill : CupertinoIcons.pencil_circle_fill,
                        color: published ? AppleColors.green : AppleColors.orange, size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(published ? 'Published' : 'Draft', style: AppleTheme.headline(context)),
                        Text(published ? 'Visible in the catalog' : 'Hidden until you publish', style: AppleTheme.footnote(context)),
                      ]),
                    ),
                    CupertinoSwitch(
                      value: published,
                      activeTrackColor: AppleColors.green,
                      onChanged: (v) async {
                        try {
                          final r = await widget.auth.apiPatch('/api/v1/manage/courses/${widget.courseId}', {'status': v ? 'published' : 'draft'});
                          ApiClient.decode(r);
                          _toast(v ? 'Published' : 'Unpublished');
                          _load();
                        } catch (_) {
                          _toast('Could not update status');
                        }
                      },
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  label: 'Edit course details',
                  icon: CupertinoIcons.pencil,
                  square: true,
                  onPressed: _editCourseDetails,
                ),
                const SizedBox(height: 14),
                // Admission control — how students get into this course.
                AppleCard(square: true, 
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(CupertinoIcons.person_2_fill, color: AppleColors.blue, size: 22),
                      const SizedBox(width: 10),
                      Text('Admission', style: AppleTheme.headline(context)),
                    ]),
                    const SizedBox(height: 12),
                    AppleSegmented(square: true, labels: _admLabels, selected: admIndex, onChanged: (i) => _setAdmission(_admModes[i])),
                    const SizedBox(height: 8),
                    Text(_admDesc[admIndex], style: AppleTheme.footnote(context)),
                  ]),
                ),
                const SizedBox(height: 18),
                Row(children: [
                  Expanded(child: SectionHeader('Modules (${modules.length})')),
                  _smallButton('Add', CupertinoIcons.add, _addModule),
                ]),
                if (modules.isEmpty)
                  AppleCard(square: true, child: Text('No modules yet. Add one, then add lessons inside it.', style: AppleTheme.footnote(context)))
                else
                  ...modules.map((m) => _moduleCard(m as Map<String, dynamic>)),

                const SizedBox(height: 22),
                Row(children: [
                  Expanded(child: SectionHeader('Live Classes (${_sessions.length})')),
                  _smallButton('Add', CupertinoIcons.videocam_fill, _addSession),
                ]),
                if (_sessions.isEmpty)
                  AppleCard(square: true, child: Text('No live classes scheduled. Add one — enrolled students will see it and can join.', style: AppleTheme.footnote(context)))
                else
                  ..._sessions.map((s) => _sessionCard(s as Map<String, dynamic>)),

                const SizedBox(height: 22),
                Row(children: [
                  Expanded(child: SectionHeader('Quizzes & Assignments (${_assessments.length})')),
                  _smallButton('Add', CupertinoIcons.doc_text_fill, _addAssignment),
                ]),
                if (_assessments.isEmpty)
                  AppleCard(square: true, child: Text('None yet. Add a quiz or assignment — students submit and you grade.', style: AppleTheme.footnote(context)))
                else
                  ..._assessmentsByDay(),

                const SizedBox(height: 22),
                PrimaryButton(
                  label: 'Batches & Settings',
                  icon: CupertinoIcons.square_stack_3d_up,
                  square: true,
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CourseBatchesScreen(auth: widget.auth, courseId: widget.courseId, title: widget.title))),
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  label: 'Doubts & Discussion',
                  icon: CupertinoIcons.chat_bubble_2_fill,
                  square: true,
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DiscussionScreen(auth: widget.auth, courseId: widget.courseId, title: widget.title))),
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  label: 'Study Hub material',
                  icon: CupertinoIcons.doc_richtext,
                  square: true,
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => StudyHubEditorScreen(auth: widget.auth, courseId: widget.courseId, title: widget.title))),
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  label: 'Issue Certificates',
                  icon: CupertinoIcons.rosette,
                  square: true,
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => _IssueCertificates(auth: widget.auth, courseId: widget.courseId, title: widget.title))),
                ),
                const SizedBox(height: 22),
                Row(children: [
                  Expanded(child: SectionHeader('Students (${_students.length})')),
                  _smallButton('Enroll', CupertinoIcons.person_add, _enroll),
                ]),
                if (_students.isEmpty)
                  AppleCard(square: true, child: Text('No students enrolled yet.', style: AppleTheme.footnote(context)))
                else
                  AppleCard(square: true, 
                    padding: EdgeInsets.zero,
                    child: Column(children: List.generate(_students.length, (i) {
                      final s = _students[i] as Map<String, dynamic>;
                      return Column(children: [
                        if (i > 0) Divider(height: 1, indent: 56, color: Palette.of(context).separator),
                        ListTile(
                          leading: Avatar(name: s['name']?.toString() ?? '?', size: 36),
                          title: Text(s['name']?.toString() ?? '', style: AppleTheme.body(context)),
                          subtitle: Text(s['email']?.toString() ?? '', style: AppleTheme.footnote(context)),
                          trailing: Text('${s['percent'] ?? 0}%', style: AppleTheme.footnote(context).copyWith(color: Palette.of(context).accent, fontWeight: FontWeight.w700)),
                        ),
                      ]);
                    })),
                  ),
              ],
            ),
    );
  }

  Widget _sessionCard(Map<String, dynamic> s) {
    final p = Palette.of(context);
    final simulated = (s['kind']?.toString() ?? 'external') == 'simulated';
    final hasLink = (s['join_url']?.toString() ?? '').isNotEmpty;
    final ready = simulated || hasLink; // a configured session vs. needs-a-link
    final hostUrl = s['host_url']?.toString() ?? '';
    final mediaTitle = s['media_title']?.toString() ?? '';
    final time = _fmtTime(s['starts_at']?.toString());
    final subtitle = simulated
        ? '$time · Recorded-as-live${mediaTitle.isNotEmpty ? ' · $mediaTitle' : ''}'
        : (hasLink ? time : '$time · No link — tap to add');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => _editSession(s),
        behavior: HitTestBehavior.opaque,
        child: AppleCard(square: true,
          child: Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(color: AppleColors.red.withOpacity(0.12), borderRadius: BorderRadius.zero),
              child: Icon(simulated ? CupertinoIcons.play_rectangle_fill : CupertinoIcons.videocam_fill, color: AppleColors.red, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s['title']?.toString() ?? 'Live class', style: AppleTheme.headline(context)),
                Text(subtitle, style: AppleTheme.footnote(context)),
              ]),
            ),
            // Host & record — opens the instructor's Zoho host link (external only).
            if (!simulated && hostUrl.isNotEmpty) ...[
              _smallButton('Host & record', CupertinoIcons.videocam_circle_fill, () => _openLink(hostUrl)),
              const SizedBox(width: 6),
            ],
            // Host console — only for recorded-as-live sessions.
            if (simulated) ...[
              _smallButton('Host', CupertinoIcons.dot_radiowaves_left_right, () => _openHost(s)),
              const SizedBox(width: 6),
            ],
            _smallButton('Edit', CupertinoIcons.pencil, () => _editSession(s)),
            const SizedBox(width: 6),
            HoverTap(onTap: () => _deleteSession(s), child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red)),
            const SizedBox(width: 8),
            Icon(ready ? (simulated ? CupertinoIcons.play_rectangle : CupertinoIcons.link) : CupertinoIcons.exclamationmark_circle,
                size: 18, color: ready ? p.secondary : AppleColors.orange),
          ]),
        ),
      ),
    );
  }

  // Open the live host console: the admin sees all student chats (private to
  // them) and can broadcast to everyone.
  void _openHost(Map<String, dynamic> s) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LiveSessionScreen(
        auth: widget.auth,
        sessionId: s['id'].toString(),
        watermark: widget.auth.user?.email ?? 'host',
        title: s['title']?.toString() ?? 'Live Class',
        isHost: true,
      ),
    ));
  }

  Future<void> _deleteSession(Map<String, dynamic> s) async {
    final yes = await showSquareConfirm(context,
        title: 'Delete live class',
        message: 'Delete “${s['title'] ?? 'this live class'}”? This removes it for all students (and its chat & Q&A). This cannot be undone.',
        confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/sessions/${s['id']}');
      _toast('Live class deleted');
      _load();
    } catch (_) {
      _toast('Could not delete');
    }
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
    } catch (_) {
      if (mounted) _toast("Couldn't open the link");
    }
  }

  // Edit a live session — its link (external) or its recording + live settings.
  Future<void> _editSession(Map<String, dynamic> s) async {
    final title = TextEditingController(text: s['title']?.toString() ?? '');
    final url = TextEditingController(text: s['join_url']?.toString() ?? '');
    final host = TextEditingController(text: s['host_url']?.toString() ?? '');
    final viewers = TextEditingController(text: '${s['viewer_base'] ?? 0}');
    int mode = (s['kind']?.toString() ?? 'external') == 'simulated' ? 1 : 0;
    String? videoId = (s['media_asset_id']?.toString() ?? '').isEmpty ? null : s['media_asset_id'].toString();
    String videoTitle = s['media_title']?.toString() ?? '';
    bool qaOn = s['qa_enabled'] != false;
    DateTime when = DateTime.tryParse(s['starts_at']?.toString() ?? '')?.toLocal() ?? DateTime.now().add(const Duration(hours: 1));
    final ok = await showFormSheet(context, square: true, title: 'Edit Live Class', builder: (setS) => [
      sheetField(title, 'Title', CupertinoIcons.textformat),
      const SizedBox(height: 10),
      AppleSegmented(square: true, labels: const ['External link', 'Recorded as live'], selected: mode, onChanged: (i) => setS(() => mode = i)),
      const SizedBox(height: 10),
      if (mode == 0) ...[
        sheetField(url, 'Join link — students attend (Zoho / Meet / Jitsi)', CupertinoIcons.link),
        const SizedBox(height: 10),
        sheetField(host, 'Host link — instructor starts & records (Zoho host URL)', CupertinoIcons.videocam_circle),
        const SizedBox(height: 6),
        _label(context, 'The host link is shown only to staff via “Host & record”. Students never see it.'),
      ] else
        ..._simLiveFields(videoId, videoTitle, qaOn, viewers,
            () => _pickFromStore((id, t) => setS(() {
                  videoId = id;
                  videoTitle = t;
                })),
            (v) => setS(() => qaOn = v)),
      const SizedBox(height: 12),
      _label(context, 'Date & time'),
      const SizedBox(height: 6),
      _DateTimeRow(value: when, onPick: (d) => setS(() => when = d)),
    ], onSubmit: () async {
      if (mode == 0 && url.text.trim().isEmpty && host.text.trim().isEmpty) return 'Add a join or host link';
      if (mode == 1 && (videoId == null || videoId!.isEmpty)) return 'Pick a video to stream';
      try {
        final body = <String, dynamic>{'title': title.text.trim(), 'starts_at': when.toUtc().toIso8601String()};
        if (mode == 0) {
          body['join_url'] = url.text.trim();
          body['host_url'] = host.text.trim();
        } else {
          body['media_asset_id'] = videoId;
          body['qa_enabled'] = qaOn;
          body['viewer_base'] = int.tryParse(viewers.text.trim()) ?? 0;
        }
        await widget.auth.apiPatch('/api/v1/manage/sessions/${s['id']}', body);
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      _toast('Live class updated');
      _load();
    }
  }

  Future<void> _addAssignment({String? moduleId, String? moduleTitle}) async {
    final title = TextEditingController();
    final maxScore = TextEditingController(text: '100');
    final day = TextEditingController();
    int type = 0; // assignment, quiz
    bool auto = false; // assignment: auto-award full points on submission
    DateTime due = DateTime.now().add(const Duration(days: 7));
    final ok = await showFormSheet(context, square: true, big: true, title: moduleId == null ? 'Add Assignment' : 'Add to "${moduleTitle ?? 'Module'}"', builder: (setS) => [
      sheetField(title, 'Title (e.g. Assignment 1)', CupertinoIcons.doc_text),
      const SizedBox(height: 10),
      AppleSegmented(square: true, labels: const ['Assignment', 'Quiz'], selected: type, onChanged: (i) => setS(() => type = i)),
      if (type == 0) ...[
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _label(context, 'Auto-award full points on submission (no manual grading). Students can write a response, paste a link, or upload files.')),
          CupertinoSwitch(value: auto, onChanged: (v) => setS(() => auto = v)),
        ]),
      ],
      const SizedBox(height: 10),
      sheetField(day, 'Day number (e.g. 1, 2, 3 — optional)', CupertinoIcons.calendar, keyboard: TextInputType.number),
      const SizedBox(height: 10),
      sheetField(maxScore, 'Max score', CupertinoIcons.number),
      const SizedBox(height: 12),
      _DateTimeRow(value: due, onPick: (d) => setS(() => due = d)),
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      try {
        await widget.auth.apiPost('/api/v1/manage/courses/${widget.courseId}/assessments', {
          'title': title.text.trim(),
          'type': type == 0 ? 'assignment' : 'quiz',
          'max_score': double.tryParse(maxScore.text.trim()) ?? 100,
          'day_number': int.tryParse(day.text.trim()),
          if (moduleId != null) 'module_id': moduleId,
          'due_at': due.toUtc().toIso8601String(),
          'is_published': true,
          'auto_award': type == 0 && auto,
        });
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      _toast('Added');
      _load();
    }
  }

  // Date-wise list: assessments grouped under "Day N" (day-less ones under
  // "Unscheduled"). Module-scoped assessments are EXCLUDED here — they live inside
  // their module's card, so module-wise and date-wise stay cleanly separate.
  List<Widget> _assessmentsByDay() {
    final groups = <int?, List<Map<String, dynamic>>>{};
    for (final a in _assessments) {
      final m = a as Map<String, dynamic>;
      if ((m['module_id']?.toString() ?? '').isNotEmpty) continue; // shown in its module
      final d = (m['day_number'] as num?)?.toInt();
      groups.putIfAbsent(d, () => []).add(m);
    }
    final keys = groups.keys.toList()
      ..sort((x, y) {
        if (x == null) return 1;
        if (y == null) return -1;
        return x.compareTo(y);
      });
    final out = <Widget>[];
    for (final k in keys) {
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Row(children: [
          Text(k == null ? 'Unscheduled' : 'Day $k',
              style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          _dayPubToggle(groups[k]!),
        ]),
      ));
      out.addAll(groups[k]!.map(_assessmentCard));
    }
    return out;
  }

  // Publish / hide EVERY assessment on a day in one tap.
  Future<void> _toggleDayPublish(List<Map<String, dynamic>> group, bool publish) async {
    try {
      await Future.wait([
        for (final a in group) widget.auth.apiPatch('/api/v1/manage/assessments/${a['id']}', {'is_published': publish}),
      ]);
      _toast(publish ? 'Day published — students can see it' : 'Day hidden from students');
      _load();
    } catch (_) {
      _toast('Could not update');
    }
  }

  Widget _dayPubToggle(List<Map<String, dynamic>> group) {
    final allPub = group.every((a) => a['is_published'] != false);
    final c = allPub ? AppleColors.green : Palette.of(context).secondary;
    return GestureDetector(
      onTap: () => _toggleDayPublish(group, !allPub),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: c.withOpacity(0.14)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(allPub ? CupertinoIcons.eye_fill : CupertinoIcons.eye_slash_fill, size: 13, color: c),
          const SizedBox(width: 4),
          Text(allPub ? 'Day visible' : 'Day hidden', style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700, color: c)),
        ]),
      ),
    );
  }

  Widget _assessmentCard(Map<String, dynamic> a) {
    final isQuiz = a['type'] == 'quiz';
    final qCount = a['questions'] ?? 0;
    final id = a['id'].toString();
    final title = a['title']?.toString() ?? 'Assessment';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => _openQuizBuilder(id, title, isQuiz: isQuiz),
        behavior: HitTestBehavior.opaque,
        child: AppleCard(square: true,
          child: Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(color: (isQuiz ? AppleColors.purple : AppleColors.blue).withOpacity(0.12), borderRadius: BorderRadius.zero),
              child: Icon(isQuiz ? CupertinoIcons.question_square_fill : CupertinoIcons.doc_text_fill, color: isQuiz ? AppleColors.purple : AppleColors.blue, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: AppleTheme.headline(context)),
                Text('${isQuiz ? 'Quiz' : 'Assignment'} · ${a['max_score'] ?? 100} pts · $qCount question${qCount == 1 ? '' : 's'}', style: AppleTheme.footnote(context)),
              ]),
            ),
            _pubToggle(id, a['is_published'] != false),
            const SizedBox(width: 8),
            if (isQuiz) ...[
              _smallButton('Questions', CupertinoIcons.list_bullet, () => _openQuizBuilder(id, title, isQuiz: isQuiz)),
              const SizedBox(width: 6),
            ],
            _smallButton('Submissions', CupertinoIcons.tray_full_fill, () => _openSubmissions(id, title, (a['max_score'] as num?) ?? 100)),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => _editAssessment(a),
              child: Icon(CupertinoIcons.pencil, size: 18, color: Palette.of(context).secondary),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () => _deleteAssessment(id, title),
              child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red),
            ),
          ]),
        ),
      ),
    );
  }

  // Open the question builder for a quiz OR assignment (list questions, add with
  // real options + correct selection, delete). Reloads the course on return so
  // question counts refresh.
  Future<void> _openQuizBuilder(String assessmentId, String title, {bool isQuiz = true}) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _QuizBuilder(auth: widget.auth, assessmentId: assessmentId, title: title, isQuiz: isQuiz)));
    _load();
  }

  // One-tap publish / hide toggle for an assessment (students only see published).
  Future<void> _toggleAssessmentPublish(String id, bool publish) async {
    try {
      await widget.auth.apiPatch('/api/v1/manage/assessments/$id', {'is_published': publish});
      _toast(publish ? 'Published — students can see it' : 'Hidden from students');
      _load();
    } catch (_) {
      _toast('Could not update');
    }
  }

  Widget _pubToggle(String id, bool published) {
    final c = published ? AppleColors.green : Palette.of(context).secondary;
    return GestureDetector(
      onTap: () => _toggleAssessmentPublish(id, !published),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(color: c.withOpacity(0.14)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(published ? CupertinoIcons.eye_fill : CupertinoIcons.eye_slash_fill, size: 13, color: c),
          const SizedBox(width: 4),
          Text(published ? 'Visible' : 'Hidden', style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700, color: c)),
        ]),
      ),
    );
  }

  // Delete an assessment and everything under it (questions + submissions).
  Future<void> _deleteAssessment(String id, String title) async {
    final yes = await showSquareConfirm(context,
        title: 'Delete assessment',
        message: 'Delete "$title" and all its questions and submissions? This cannot be undone.',
        confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/assessments/$id');
      _toast('Deleted');
      _load();
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Could not delete');
    }
  }

  // Edit an assessment: title, type, score, due date, publish, and its scope —
  // organised by Day (date-wise) OR Module (module-wise), kept mutually exclusive.
  Future<void> _editAssessment(Map<String, dynamic> a) async {
    final id = a['id'].toString();
    final title = TextEditingController(text: a['title']?.toString() ?? '');
    final maxScore = TextEditingController(text: '${a['max_score'] ?? 100}');
    final day = TextEditingController(text: a['day_number'] == null ? '' : '${a['day_number']}');
    int type = a['type'] == 'quiz' ? 1 : 0;
    bool published = a['is_published'] != false;
    bool auto = a['auto_award'] == true;
    final modules = (_course?['modules'] as List?) ?? [];
    int scope = (a['module_id']?.toString() ?? '').isNotEmpty ? 1 : 0; // 0=day, 1=module
    String moduleId = a['module_id']?.toString() ?? (modules.isNotEmpty ? modules.first['id'].toString() : '');
    DateTime due = DateTime.tryParse(a['due_at']?.toString() ?? '')?.toLocal() ?? DateTime.now().add(const Duration(days: 7));
    final ok = await showFormSheet(context, square: true, big: true, title: 'Edit ${type == 1 ? 'Quiz' : 'Assignment'}', builder: (setS) => [
      sheetField(title, 'Title', CupertinoIcons.doc_text),
      const SizedBox(height: 10),
      AppleSegmented(square: true, labels: const ['Assignment', 'Quiz'], selected: type, onChanged: (i) => setS(() => type = i)),
      const SizedBox(height: 12),
      Text('Organize by', style: AppleTheme.footnote(context)),
      const SizedBox(height: 6),
      AppleSegmented(square: true, labels: const ['Day', 'Module'], selected: scope, onChanged: (i) => setS(() => scope = i)),
      if (scope == 0) ...[
        const SizedBox(height: 10),
        sheetField(day, 'Day number (blank = unscheduled)', CupertinoIcons.calendar, keyboard: TextInputType.number),
      ] else if (modules.isEmpty) ...[
        const SizedBox(height: 8),
        Text('Add a module first to scope it module-wise.', style: AppleTheme.footnote(context)),
      ] else ...[
        const SizedBox(height: 8),
        ...modules.map((mm) {
          final mid = (mm as Map)['id'].toString();
          final sel = mid == moduleId;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setS(() => moduleId = mid),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Icon(sel ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle, size: 20, color: sel ? Palette.of(context).accent : Palette.of(context).secondary),
                const SizedBox(width: 10),
                Expanded(child: Text(mm['title']?.toString() ?? 'Module', style: AppleTheme.body(context))),
              ]),
            ),
          );
        }),
      ],
      const SizedBox(height: 10),
      sheetField(maxScore, 'Max score', CupertinoIcons.number, keyboard: TextInputType.number),
      const SizedBox(height: 12),
      _DateTimeRow(value: due, onPick: (d) => setS(() => due = d)),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: Text('Published', style: AppleTheme.body(context))),
        CupertinoSwitch(value: published, onChanged: (v) => setS(() => published = v)),
      ]),
      if (type == 0) ...[
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: _label(context, 'Auto-award full points on submission')),
          CupertinoSwitch(value: auto, onChanged: (v) => setS(() => auto = v)),
        ]),
      ],
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      final body = <String, dynamic>{
        'title': title.text.trim(),
        'type': type == 1 ? 'quiz' : 'assignment',
        'max_score': double.tryParse(maxScore.text.trim()) ?? 100,
        'is_published': published,
        'auto_award': type == 0 && auto,
        'due_at': due.toUtc().toIso8601String(),
      };
      if (scope == 1 && moduleId.isNotEmpty) {
        body['module_id'] = moduleId; // server clears day_number
      } else {
        body['module_id'] = ''; // clear module scope
        final dn = int.tryParse(day.text.trim());
        if (dn != null) {
          body['day_number'] = dn;
        } else {
          body['clear_day'] = true;
        }
      }
      try {
        await widget.auth.apiPatch('/api/v1/manage/assessments/$id', body);
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      _toast('Saved');
      _load();
    }
  }

  // Open the Video Store as a picker (browse / upload / choose), returning the
  // chosen asset's id + title. Used by the recorded-as-live flow.
  Future<void> _pickFromStore(void Function(String id, String title) onPicked) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (sctx) => VideoStoreScreen(
        auth: widget.auth,
        onPick: (id, url, title) {
          onPicked(id, title);
          Navigator.of(sctx).pop();
        },
      ),
    ));
  }

  // The recorded-as-live form fields: a "Choose from Video Store" button (opens
  // the full store) + the current pick + a Q&A toggle + the viewer floor.
  List<Widget> _simLiveFields(String? videoId, String videoTitle, bool qaOn,
      TextEditingController viewers, VoidCallback onOpenStore, void Function(bool) onQa) {
    final p = Palette.of(context);
    final picked = videoId != null && videoId.isNotEmpty;
    return [
      _label(context, 'Choose a video from the store — it streams as a live class from the scheduled start time (no skipping, no pause).'),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(color: p.card2, border: Border.all(color: p.separator)),
        child: Row(children: [
          Icon(picked ? CupertinoIcons.film_fill : CupertinoIcons.film, size: 18, color: picked ? AppleColors.green : p.secondary),
          const SizedBox(width: 10),
          Expanded(child: Text(picked ? videoTitle : 'No video chosen yet', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppleTheme.body(context))),
        ]),
      ),
      const SizedBox(height: 8),
      PrimaryButton(label: picked ? 'Change video' : 'Choose from Video Store', icon: CupertinoIcons.film, square: true, onPressed: onOpenStore),
      const SizedBox(height: 12),
      Row(children: [Expanded(child: _label(context, 'Allow questions (Q&A to host)')), CupertinoSwitch(value: qaOn, onChanged: onQa)]),
      const SizedBox(height: 8),
      sheetField(viewers, 'Starting viewers (displayed-count floor)', CupertinoIcons.eye, keyboard: TextInputType.number),
    ];
  }

  Future<void> _addSession() async {
    final title = TextEditingController();
    final url = TextEditingController();
    final host = TextEditingController();
    final viewers = TextEditingController(text: '0');
    DateTime when = DateTime.now().add(const Duration(hours: 1));
    int mode = 0; // 0 = external link, 1 = recorded-as-live
    String? videoId;
    String videoTitle = '';
    bool qaOn = true;
    final ok = await showFormSheet(context, square: true, title: 'Add Live Class', builder: (setS) => [
      sheetField(title, 'Title (e.g. Lecture 1)', CupertinoIcons.textformat),
      const SizedBox(height: 10),
      AppleSegmented(square: true, labels: const ['External link', 'Recorded as live'], selected: mode, onChanged: (i) => setS(() => mode = i)),
      const SizedBox(height: 10),
      if (mode == 0) ...[
        sheetField(url, 'Join link — students attend', CupertinoIcons.link),
        const SizedBox(height: 10),
        sheetField(host, 'Host link — instructor records (Zoho host URL, optional)', CupertinoIcons.videocam_circle),
      ] else
        ..._simLiveFields(videoId, videoTitle, qaOn, viewers,
            () => _pickFromStore((id, t) => setS(() {
                  videoId = id;
                  videoTitle = t;
                })),
            (v) => setS(() => qaOn = v)),
      const SizedBox(height: 12),
      _DateTimeRow(value: when, onPick: (d) => setS(() => when = d)),
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      if (mode == 0 && url.text.trim().isEmpty) return 'Join link required';
      if (mode == 1 && (videoId == null || videoId!.isEmpty)) return 'Pick a video to stream';
      try {
        final body = <String, dynamic>{'title': title.text.trim(), 'starts_at': when.toUtc().toIso8601String()};
        if (mode == 0) {
          body['join_url'] = url.text.trim();
          body['host_url'] = host.text.trim();
        } else {
          body['media_asset_id'] = videoId;
          body['qa_enabled'] = qaOn;
          body['viewer_base'] = int.tryParse(viewers.text.trim()) ?? 0;
        }
        await widget.auth.apiPost('/api/v1/manage/courses/${widget.courseId}/sessions', body);
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      _toast('Live class scheduled');
      _load();
    }
  }

  Widget _moduleCard(Map<String, dynamic> m, {bool isSub = false}) {
    final lessons = (m['lessons'] as List?) ?? [];
    final subs = (m['submodules'] as List?) ?? [];
    final mid = m['id'].toString();
    final mtitle = m['title']?.toString() ?? 'Module';
    return Padding(
      padding: EdgeInsets.only(bottom: isSub ? 8 : 12, left: isSub ? 14 : 0),
      child: AppleCard(square: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _editModule(m),
              child: Row(children: [
                if (isSub) Padding(padding: const EdgeInsets.only(right: 6), child: Icon(Icons.subdirectory_arrow_right, size: 16, color: Palette.of(context).secondary)),
                Flexible(child: Text(mtitle, style: isSub ? AppleTheme.body(context).copyWith(fontWeight: FontWeight.w700) : AppleTheme.headline(context))),
                const SizedBox(width: 6),
                Icon(CupertinoIcons.pencil, size: 15, color: Palette.of(context).secondary),
              ]),
            )),
            _smallButton('Material', CupertinoIcons.add, () => _addLesson(mid)),
            const SizedBox(width: 6),
            _smallButton('Quiz', CupertinoIcons.doc_text_fill, () => _addAssignment(moduleId: mid, moduleTitle: mtitle)),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => _confirmDelete(isSub ? 'Delete this sub-module and its lessons?' : 'Delete this module and its lessons?', () =>
                  widget.auth.apiDelete('/api/v1/manage/modules/$mid')),
              child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red),
            ),
          ]),
          if (lessons.isNotEmpty) ...[
            const SizedBox(height: 8),
            // Content grouped by day within the module (Day 1, Day 2, …).
            ..._lessonsByDay(lessons),
          ],
          // Quizzes & assignments scoped to this module.
          ..._moduleAssessments(mid),
          // Nested sub-modules.
          if (subs.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...subs.map((s) => _moduleCard(s as Map<String, dynamic>, isSub: true)),
          ],
          // Add a sub-module (top-level modules only — one level of nesting).
          if (!isSub) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: _smallButton('Sub-module', CupertinoIcons.folder_badge_plus, () => _addModule(parentId: mid, parentTitle: mtitle)),
            ),
          ],
        ]),
      ),
    );
  }

  // Group a module's lessons by day (null day → trailing "Unscheduled").
  List<Widget> _lessonsByDay(List lessons) {
    final groups = <int?, List<Map<String, dynamic>>>{};
    for (final l in lessons) {
      final ll = l as Map<String, dynamic>;
      groups.putIfAbsent((ll['day_number'] as num?)?.toInt(), () => []).add(ll);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        if (a == null) return 1;
        if (b == null) return -1;
        return a.compareTo(b);
      });
    final out = <Widget>[];
    for (final k in keys) {
      final ls = groups[k]!;
      out.add(_DayFolder(
        label: k == null ? 'Unscheduled' : 'Day $k',
        count: ls.length,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          _dayScheduleControl(ls),
          const SizedBox(width: 8),
          _dayVisibleToggle(ls),
        ]),
        children: [for (var i = 0; i < ls.length; i++) _lessonRow(ls[i], ls, i)],
      ));
    }
    return out;
  }

  Widget _dayVisibleToggle(List<Map<String, dynamic>> ls) {
    final allPub = ls.every((l) => l['is_published'] != false);
    final tc = allPub ? AppleColors.green : Palette.of(context).secondary;
    return GestureDetector(
      onTap: () => _toggleDayLessonsPublish(ls, !allPub),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: tc.withOpacity(0.14)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(allPub ? CupertinoIcons.eye_fill : CupertinoIcons.eye_slash_fill, size: 12, color: tc),
          const SizedBox(width: 4),
          Text(allPub ? 'Visible' : 'Hidden', style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700, color: tc)),
        ]),
      ),
    );
  }

  // A calendar chip on the day header: schedule when the whole day's materials
  // go live. Tap to pick a date; tap the × (when scheduled) to clear.
  Widget _dayScheduleControl(List<Map<String, dynamic>> ls) {
    final p = Palette.of(context);
    DateTime? sched;
    for (final l in ls) {
      final s = l['publish_at']?.toString() ?? '';
      if (s.isNotEmpty) {
        final d = DateTime.tryParse(s)?.toLocal();
        if (d != null && (sched == null || d.isAfter(sched))) sched = d;
      }
    }
    const mon = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    if (sched == null) {
      return GestureDetector(
        onTap: () => _scheduleDay(ls),
        child: Icon(CupertinoIcons.calendar_badge_plus, size: 16, color: p.secondary),
      );
    }
    return GestureDetector(
      onTap: () => _scheduleDay(ls),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: AppleColors.blue.withOpacity(0.14)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(CupertinoIcons.calendar, size: 12, color: AppleColors.blue),
          const SizedBox(width: 4),
          Text('${sched.day} ${mon[sched.month]}', style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700, color: AppleColors.blue)),
          const SizedBox(width: 6),
          GestureDetector(onTap: () => _setDayPublishAt(ls, null), child: Icon(CupertinoIcons.xmark, size: 11, color: AppleColors.blue)),
        ]),
      ),
    );
  }

  Future<void> _scheduleDay(List<Map<String, dynamic>> ls) async {
    DateTime init = DateTime.now().add(const Duration(days: 1));
    for (final l in ls) {
      final s = l['publish_at']?.toString() ?? '';
      if (s.isNotEmpty) {
        final d = DateTime.tryParse(s)?.toLocal();
        if (d != null) init = d;
      }
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (picked == null) return;
    final dt = DateTime(picked.year, picked.month, picked.day); // local midnight
    await _setDayPublishAt(ls, dt.toUtc().toIso8601String());
  }

  Future<void> _setDayPublishAt(List<Map<String, dynamic>> ls, String? iso) async {
    try {
      await Future.wait([
        for (final l in ls) widget.auth.apiPatch('/api/v1/manage/lessons/${l['id']}', {'publish_at': iso ?? ''}),
      ]);
      _toast(iso == null ? 'Publishes immediately now' : 'Day scheduled — publishes on that date');
      _load();
    } catch (_) {
      _toast('Could not update');
    }
  }

  Widget _lessonRow(Map<String, dynamic> ll, List<Map<String, dynamic>> group, int index) {
    final p = Palette.of(context);
    final canUp = index > 0;
    final canDown = index < group.length - 1;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Icon(_iconFor(ll['type']?.toString() ?? 'text'), size: 17, color: p.secondary),
        const SizedBox(width: 10),
        Expanded(child: Text(ll['title']?.toString() ?? '', style: AppleTheme.body(context).copyWith(fontSize: 15))),
        // Reorder within the day (move the material up / down).
        GestureDetector(
          onTap: canUp ? () => _moveLesson(group, index, -1) : null,
          child: Icon(CupertinoIcons.chevron_up, size: 16, color: canUp ? p.secondary : p.separator),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: canDown ? () => _moveLesson(group, index, 1) : null,
          child: Icon(CupertinoIcons.chevron_down, size: 16, color: canDown ? p.secondary : p.separator),
        ),
        const SizedBox(width: 14),
        GestureDetector(
          onTap: () => _toggleLessonPublish(ll['id'].toString(), ll['is_published'] == false),
          child: Icon(ll['is_published'] != false ? CupertinoIcons.eye_fill : CupertinoIcons.eye_slash_fill,
              size: 16, color: ll['is_published'] != false ? AppleColors.green : p.secondary),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: () => _editLesson(ll),
          child: Icon(CupertinoIcons.pencil, size: 16, color: p.secondary),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: () => _confirmDelete('Delete this lesson?', () =>
              widget.auth.apiDelete('/api/v1/manage/lessons/${ll['id']}')),
          child: Icon(CupertinoIcons.minus_circle, size: 17, color: AppleColors.red.withOpacity(0.8)),
        ),
      ]),
    );
  }

  // Publish / hide a single course material (students only see published ones).
  Future<void> _toggleLessonPublish(String id, bool publish) async {
    try {
      await widget.auth.apiPatch('/api/v1/manage/lessons/$id', {'is_published': publish});
      _toast(publish ? 'Material published' : 'Material hidden from students');
      _load();
    } catch (_) {
      _toast('Could not update');
    }
  }

  // Publish / hide EVERY material on a day at once.
  Future<void> _toggleDayLessonsPublish(List<Map<String, dynamic>> group, bool publish) async {
    try {
      await Future.wait([
        for (final l in group) widget.auth.apiPatch('/api/v1/manage/lessons/${l['id']}', {'is_published': publish}),
      ]);
      _toast(publish ? 'Day published' : 'Day hidden from students');
      _load();
    } catch (_) {
      _toast('Could not update');
    }
  }

  // Move a material up/down within its day group: reassign sequential positions
  // (0,1,2,…) to the new order and persist, then reload.
  Future<void> _moveLesson(List<Map<String, dynamic>> group, int index, int delta) async {
    final target = index + delta;
    if (target < 0 || target >= group.length) return;
    final reordered = [...group];
    final item = reordered.removeAt(index);
    reordered.insert(target, item);
    try {
      await Future.wait([
        for (var i = 0; i < reordered.length; i++)
          widget.auth.apiPatch('/api/v1/manage/lessons/${reordered[i]['id']}', {'position': i}),
      ]);
    } catch (_) {}
    await _load();
  }

  // Quizzes/assignments attached to a specific module (shown inside its card).
  List<Widget> _moduleAssessments(String moduleId) {
    final items = _assessments.where((a) => (a as Map)['module_id']?.toString() == moduleId).toList();
    if (items.isEmpty) return [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Text('Quizzes & assignments', style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700)),
      ),
      ...items.map((a) {
        final m = a as Map<String, dynamic>;
        final isQuiz = m['type'] == 'quiz';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(isQuiz ? CupertinoIcons.question_square_fill : CupertinoIcons.doc_text_fill, size: 16, color: isQuiz ? AppleColors.purple : AppleColors.blue),
            const SizedBox(width: 10),
            Expanded(child: Text('${m['title']}${(m['questions'] ?? 0) != 0 ? ' · ${m['questions']} Qs' : ''}', style: AppleTheme.body(context).copyWith(fontSize: 14))),
            _pubToggle(m['id'].toString(), m['is_published'] != false),
            const SizedBox(width: 6),
            if (isQuiz) ...[
              _smallButton('Questions', CupertinoIcons.list_bullet, () => _openQuizBuilder(m['id'].toString(), m['title']?.toString() ?? 'Quiz', isQuiz: isQuiz)),
              const SizedBox(width: 6),
            ],
            _smallButton('Submissions', CupertinoIcons.tray_full_fill, () => _openSubmissions(m['id'].toString(), m['title']?.toString() ?? (isQuiz ? 'Quiz' : 'Assignment'), (m['max_score'] as num?) ?? 100)),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => _editAssessment(m),
              child: Icon(CupertinoIcons.pencil, size: 16, color: Palette.of(context).secondary),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _confirmDelete('Delete this ${isQuiz ? 'quiz' : 'assignment'}?', () => widget.auth.apiDelete('/api/v1/manage/assessments/${m['id']}')),
              child: Icon(CupertinoIcons.minus_circle, size: 16, color: AppleColors.red.withOpacity(0.8)),
            ),
          ]),
        );
      }),
    ];
  }

  // Open the grading queue for an assignment (student submissions).
  void _openSubmissions(String assessId, String title, num maxScore) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _SubmissionsScreen(auth: widget.auth, assessId: assessId, title: title, maxScore: maxScore),
    ));
  }

  Future<void> _confirmDelete(String message, Future<dynamic> Function() action) async {
    final yes = await showSquareConfirm(context, title: 'Delete', message: message, confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await action();
      _toast('Deleted');
      _load();
    } catch (_) {
      _toast('Could not delete');
    }
  }

  IconData _iconFor(String t) => switch (t) {
        'video' => CupertinoIcons.play_rectangle,
        'scorm' || 'xapi' => CupertinoIcons.cube_box,
        'link' => CupertinoIcons.link,
        'file' => CupertinoIcons.doc_richtext,
        _ => CupertinoIcons.doc_text,
      };

  Widget _smallButton(String label, IconData icon, VoidCallback onTap) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: p.accent.withOpacity(0.12), borderRadius: BorderRadius.zero),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: p.accent),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: p.accent, fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Future<void> _addModule({String? parentId, String? parentTitle}) async {
    final title = TextEditingController();
    final sub = parentId != null;
    final ok = await showFormSheet(context, square: true, big: true,
        title: sub ? 'Add Sub-module to "${parentTitle ?? 'Module'}"' : 'Add Module',
        builder: (_) => [sheetField(title, sub ? 'Sub-module title' : 'Module title', CupertinoIcons.folder)],
        onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      await widget.auth.apiPost('/api/v1/manage/courses/${widget.courseId}/modules', {
        'title': title.text.trim(),
        if (sub) 'parent_module_id': parentId,
      });
      return null;
    });
    if (ok == true) _load();
  }

  Future<void> _addLesson(String moduleId) async {
    final title = TextEditingController();
    final body = TextEditingController();
    final day = TextEditingController();
    int type = 0; // text, video, link
    int vsrc = 0; // 0 = R2 (MP4), 1 = HLS (.m3u8)
    bool downloadable = true; // documents: may learners download it?
    bool preview = false; // text content: Write ⇄ Preview (rendered Markdown)
    final ok = await showFormSheet(context, square: true, full: true, title: 'Add Course Material', builder: (setS) => [
      sheetField(title, 'Lesson title', CupertinoIcons.doc_text),
      const SizedBox(height: 10),
      sheetField(day, 'Day in module (e.g. 1) — optional', CupertinoIcons.calendar, keyboard: TextInputType.number),
      const SizedBox(height: 10),
      AppleSegmented(square: true, labels: const ['Text', 'Video', 'Link', 'Document'], selected: type, onChanged: (i) => setS(() => type = i)),
      if (type == 1) ...[
        const SizedBox(height: 12),
        _label(context, 'Video source'),
        const SizedBox(height: 6),
        AppleSegmented(square: true, labels: const ['R2 (MP4)', 'HLS (.m3u8)'], selected: vsrc, onChanged: (i) => setS(() => vsrc = i)),
        if (vsrc == 0) ...[
          const SizedBox(height: 8),
          PrimaryButton(
            label: 'Choose from Video Store',
            icon: CupertinoIcons.film,
            square: true,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => VideoStoreScreen(auth: widget.auth, onPick: (id, url, t) {
                body.text = url;
                if (title.text.trim().isEmpty) title.text = t;
                setS(() {});
                Navigator.of(context).pop();
              }),
            )),
          ),
        ],
      ],
      const SizedBox(height: 10),
      if (type == 0)
        ..._mdEditor(context, body: body, preview: preview, onPreview: (v) => setS(() => preview = v), refresh: () => setS(() {}))
      else
        sheetField(
          body,
          type == 1
              ? (vsrc == 0 ? 'R2 video URL (…/video.mp4)' : 'HLS playlist URL (…/index.m3u8)')
              : type == 3
                  ? 'Document URL (PDF / Word / PPT …)'
                  : 'URL',
          type == 1
              ? (vsrc == 0 ? CupertinoIcons.play_rectangle : CupertinoIcons.antenna_radiowaves_left_right)
              : type == 3
                  ? CupertinoIcons.doc_richtext
                  : CupertinoIcons.link,
        ),
      if (type == 3) ...[
        const SizedBox(height: 6),
        _label(context, 'Link a PDF / Word / PowerPoint or any document URL. Students open it from the lesson.'),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _label(context, 'Allow learners to download this document')),
          CupertinoSwitch(value: downloadable, activeTrackColor: AppleColors.green, onChanged: (v) => setS(() => downloadable = v)),
        ]),
      ],
      if (type == 1) ...[
        const SizedBox(height: 6),
        _label(context, vsrc == 0
            ? 'Direct MP4 stored in Cloudflare R2. Streams; no download.'
            : 'HLS playlist (.m3u8) from R2/CDN. Adaptive streaming via hls.js.'),
      ],
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      if (type != 0 && body.text.trim().isEmpty) return type == 1 ? 'Video URL required' : (type == 3 ? 'Document URL required' : 'URL required');
      await widget.auth.apiPost('/api/v1/manage/modules/$moduleId/lessons', {
        'title': title.text.trim(),
        'type': ['text', 'video', 'link', 'file'][type],
        'body': body.text.trim(),
        if (type == 3) 'downloadable': downloadable,
        if (int.tryParse(day.text.trim()) != null) 'day_number': int.parse(day.text.trim()),
      });
      return null;
    });
    if (ok == true) _load();
  }

  // Edit the course's own details — title, ID/label, description, cover image.
  Future<void> _editCourseDetails() async {
    final c = _course ?? <String, dynamic>{};
    // Load instructors so the admin can (re)assign the course instructor.
    List<dynamic> instructors = [];
    try {
      instructors = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/instructors'))['instructors'] as List?) ?? [];
    } catch (_) {}
    if (!mounted) return;
    final title = TextEditingController(text: c['title']?.toString() ?? widget.title);
    final courseId = TextEditingController(text: c['label']?.toString() ?? '');
    final desc = TextEditingController(text: c['description']?.toString() ?? '');
    final imageUrl = TextEditingController(text: c['image_url']?.toString() ?? '');
    // Preselect the current instructor (owner) if it's still an instructor.
    String? instructorId = c['owner_id']?.toString();
    if ((instructorId == null || instructorId.isEmpty) && instructors.isNotEmpty) {
      instructorId = instructors.first['id'].toString();
    }
    final ok = await showFormSheet(context, square: true, title: 'Edit Course Details', builder: (setS) => [
      sheetField(title, 'Display title (shown to students)', CupertinoIcons.textformat),
      const SizedBox(height: 10),
      sheetField(courseId, 'Course ID — unique label (e.g. aiarchitect)', CupertinoIcons.tag),
      const SizedBox(height: 10),
      sheetField(desc, 'Description', CupertinoIcons.text_alignleft),
      const SizedBox(height: 10),
      sheetField(imageUrl, 'Cover image URL (optional)', CupertinoIcons.photo),
      if (instructors.isNotEmpty) ...[
        const SizedBox(height: 12),
        _label(context, 'Assign instructor'),
        const SizedBox(height: 6),
        _InstructorDropdown(
          instructors: instructors,
          selectedId: instructorId ?? instructors.first['id'].toString(),
          onChanged: (id) => setS(() => instructorId = id),
        ),
      ],
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      final body = <String, dynamic>{'title': title.text.trim(), 'description': desc.text.trim()};
      if (courseId.text.trim().isNotEmpty) body['label'] = courseId.text.trim();
      if (imageUrl.text.trim().isNotEmpty) body['image_url'] = imageUrl.text.trim();
      if (instructorId != null && instructorId!.isNotEmpty) body['instructor_id'] = instructorId;
      try {
        await widget.auth.apiPatch('/api/v1/manage/courses/${widget.courseId}', body);
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      _toast('Saved');
      _load();
    }
  }

  // Rename a module.
  Future<void> _editModule(Map<String, dynamic> m) async {
    final title = TextEditingController(text: m['title']?.toString() ?? '');
    final ok = await showFormSheet(context, square: true, title: 'Edit Module',
        builder: (_) => [sheetField(title, 'Module title', CupertinoIcons.folder)],
        onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      try {
        await widget.auth.apiPatch('/api/v1/manage/modules/${m['id']}', {'title': title.text.trim()});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      _toast('Saved');
      _load();
    }
  }

  // Edit a lesson's title, type, content/URL, and (for documents) download flag.
  Future<void> _editLesson(Map<String, dynamic> l) async {
    final title = TextEditingController(text: l['title']?.toString() ?? '');
    final body = TextEditingController(text: (l['body'] ?? l['url'] ?? '').toString());
    final day = TextEditingController(text: l['day_number'] == null ? '' : '${l['day_number']}');
    const types = ['text', 'video', 'link', 'file'];
    int type = types.indexOf(l['type']?.toString() ?? 'text');
    if (type < 0) type = 0;
    bool downloadable = l['downloadable'] != false;
    bool preview = false; // text content: Write ⇄ Preview (rendered Markdown)
    final ok = await showFormSheet(context, square: true, full: true, title: 'Edit Course Material', builder: (setS) => [
      sheetField(title, 'Lesson title', CupertinoIcons.doc_text),
      const SizedBox(height: 10),
      sheetField(day, 'Day in module (e.g. 1) — blank = unscheduled', CupertinoIcons.calendar, keyboard: TextInputType.number),
      const SizedBox(height: 10),
      AppleSegmented(square: true, labels: const ['Text', 'Video', 'Link', 'Document'], selected: type, onChanged: (i) => setS(() => type = i)),
      const SizedBox(height: 10),
      if (type == 0)
        ..._mdEditor(context, body: body, preview: preview, onPreview: (v) => setS(() => preview = v), refresh: () => setS(() {}))
      else
        sheetField(
          body,
          type == 1 ? 'Video URL' : (type == 3 ? 'Document URL' : 'URL'),
          type == 1 ? CupertinoIcons.play_rectangle : (type == 3 ? CupertinoIcons.doc_richtext : CupertinoIcons.link),
        ),
      if (type == 3) ...[
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: Text('Allow learners to download', style: AppleTheme.body(context))),
          CupertinoSwitch(value: downloadable, activeTrackColor: AppleColors.green, onChanged: (v) => setS(() => downloadable = v)),
        ]),
      ],
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      if (type != 0 && body.text.trim().isEmpty) return 'URL required';
      try {
        final dn = int.tryParse(day.text.trim());
        await widget.auth.apiPatch('/api/v1/manage/lessons/${l['id']}', {
          'title': title.text.trim(),
          'type': types[type],
          'body': body.text.trim(),
          if (type == 3) 'downloadable': downloadable,
          if (dn != null) 'day_number': dn,
          if (dn == null) 'clear_day': true,
        });
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      _toast('Saved');
      _load();
    }
  }

  Future<void> _enroll() async {
    final email = TextEditingController();
    final ok = await showFormSheet(context, square: true, title: 'Enroll Student',
        builder: (_) => [sheetField(email, 'Student email', CupertinoIcons.mail)],
        onSubmit: () async {
      if (email.text.trim().isEmpty) return 'Email required';
      try {
        await widget.auth.apiPost('/api/v1/manage/courses/${widget.courseId}/enroll', {'email': email.text.trim()});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) _toast('Student enrolled');
  }
}

/// Announcements hub — compose new broadcasts and delete existing ones.
class _AnnouncementsSheet extends StatefulWidget {
  const _AnnouncementsSheet({required this.auth, required this.onNew});
  final AuthService auth;
  final Future<void> Function() onNew; // opens the compose sheet

  @override
  State<_AnnouncementsSheet> createState() => _AnnouncementsSheetState();
}

class _AnnouncementsSheetState extends State<_AnnouncementsSheet> {
  List<dynamic> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/announcements'))['announcements'] as List?) ?? [];
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _delete(Map<String, dynamic> a) async {
    final yes = await showSquareConfirm(context,
        title: 'Delete announcement?',
        message: '"${a['title'] ?? ''}" will be removed for everyone.',
        confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/announcements/${a['id']}');
    } catch (_) {}
    await _load();
  }

  String _audience(Map<String, dynamic> a) {
    switch (a['audience']?.toString()) {
      case 'batch':
        return 'Batch ${a['batch_number'] ?? ''}';
      case 'role':
        return '${a['role'] ?? ''}s';
      default:
        return 'Everyone';
    }
  }

  String _fmtDate(String? iso) {
    final dt = DateTime.tryParse(iso ?? '')?.toLocal();
    if (dt == null) return '';
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${m[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final h = MediaQuery.of(context).size.height;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Align(
        alignment: Alignment.center,
        child: Container(
          margin: const EdgeInsets.all(16),
          constraints: BoxConstraints(maxWidth: 720, maxHeight: h * 0.85),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(color: p.card),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('Announcements', style: AppleTheme.title2(context))),
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => Navigator.pop(context), child: Icon(CupertinoIcons.xmark, color: p.secondary)),
            ]),
            const SizedBox(height: 14),
            PrimaryButton(label: 'New announcement', icon: CupertinoIcons.add, square: true, onPressed: () async {
              await widget.onNew();
              await _load();
            }),
            const SizedBox(height: 14),
            Flexible(
              child: _loading
                  ? const Padding(padding: EdgeInsets.symmetric(vertical: 40), child: Center(child: CupertinoActivityIndicator()))
                  : _items.isEmpty
                      ? Padding(padding: const EdgeInsets.symmetric(vertical: 30), child: Text('No announcements yet.', textAlign: TextAlign.center, style: AppleTheme.footnote(context)))
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: _items.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (_, i) {
                            final a = _items[i] as Map<String, dynamic>;
                            final body = a['body']?.toString() ?? '';
                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(color: p.card2, border: Border.all(color: p.separator)),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(a['title']?.toString() ?? '', style: AppleTheme.body(context).copyWith(fontWeight: FontWeight.w700)),
                                  if (body.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(body, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppleTheme.footnote(context)),
                                  ],
                                  const SizedBox(height: 4),
                                  Text('${_audience(a)} · ${_fmtDate(a['at']?.toString())}', style: AppleTheme.footnote(context).copyWith(color: p.secondary)),
                                ])),
                                const SizedBox(width: 8),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => _delete(a),
                                  child: const Padding(padding: EdgeInsets.all(2), child: Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red)),
                                ),
                              ]),
                            );
                          },
                        ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Admin device control — lists a user's active devices with per-device revoke
/// and a "reset all" action (frees device slots when someone changes phones).
class _DeviceSheet extends StatefulWidget {
  const _DeviceSheet({required this.auth, required this.userId, required this.name, required this.email});
  final AuthService auth;
  final String userId;
  final String name;
  final String email;

  @override
  State<_DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<_DeviceSheet> {
  List<dynamic> _devices = [];
  bool _loading = true;
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _err = null; });
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/users/${widget.userId}/devices');
      _devices = (ApiClient.decode(r)['devices'] as List?) ?? [];
    } catch (_) {
      _err = 'Could not load devices';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _revoke(String deviceRowId) async {
    setState(() => _busy = true);
    try {
      await widget.auth.apiDelete('/api/v1/manage/users/${widget.userId}/devices/$deviceRowId');
    } catch (_) {}
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _resetAll() async {
    final yes = await showSquareConfirm(context,
        title: 'Reset all devices?',
        message: '${widget.name} will be signed out on all devices and can bind fresh ones.',
        confirmLabel: 'Reset', destructive: true);
    if (!yes) return;
    setState(() => _busy = true);
    try {
      await widget.auth.apiDelete('/api/v1/manage/users/${widget.userId}/devices');
    } catch (_) {}
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  IconData _platformIcon(String? platform) {
    final p = (platform ?? '').toLowerCase();
    if (p.contains('web')) return CupertinoIcons.globe;
    if (p.contains('mac') || p.contains('windows') || p.contains('linux')) return CupertinoIcons.device_laptop;
    return CupertinoIcons.device_phone_portrait;
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        margin: const EdgeInsets.all(10),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.zero),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Text('Devices', style: AppleTheme.title2(context))),
          const SizedBox(height: 2),
          Center(child: Text(widget.name, style: AppleTheme.footnote(context))),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(padding: EdgeInsets.symmetric(vertical: 26), child: Center(child: CupertinoActivityIndicator()))
          else if (_err != null)
            Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(_err!, textAlign: TextAlign.center, style: AppleTheme.footnote(context).copyWith(color: AppleColors.red)))
          else if (_devices.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text('No active devices.', textAlign: TextAlign.center, style: AppleTheme.footnote(context)))
          else
            ..._devices.map((d) {
              final m = d as Map<String, dynamic>;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.zero),
                  child: Row(children: [
                    Icon(_platformIcon(m['platform']?.toString()), size: 22, color: p.secondary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                          (m['model']?.toString().isNotEmpty ?? false) ? m['model'].toString() : (m['platform']?.toString() ?? 'Device'),
                          style: AppleTheme.body(context).copyWith(fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        Text('Last seen ${_fmtTime(m['last_seen']?.toString())}', style: AppleTheme.footnote(context)),
                      ]),
                    ),
                    GestureDetector(
                      onTap: _busy ? null : () => _revoke(m['id'].toString()),
                      child: const Padding(padding: EdgeInsets.all(4), child: Icon(CupertinoIcons.minus_circle_fill, color: AppleColors.red, size: 24)),
                    ),
                  ]),
                ),
              );
            }),
          const SizedBox(height: 8),
          if (widget.email.isNotEmpty)
            PrimaryButton(
              label: 'Assign to a course',
              icon: CupertinoIcons.book_fill,
              busy: _busy,
              square: true,
              onPressed: _assignCourse,
            ),
          const SizedBox(height: 10),
          PrimaryButton(
            label: 'Reset all devices',
            icon: CupertinoIcons.arrow_counterclockwise,
            busy: _busy,
            square: true,
            onPressed: _devices.isEmpty ? null : _resetAll,
          ),
          const SizedBox(height: 6),
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Done', style: TextStyle(color: p.secondary))),
        ]),
      ),
    );
  }

  // Fetch the course list and enroll this student in the picked course.
  Future<void> _assignCourse() async {
    List<dynamic> courses = [];
    try {
      courses = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/courses'))['courses'] as List?) ?? [];
    } catch (_) {}
    if (!mounted) return;
    if (courses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No courses to assign'), behavior: SnackBarBehavior.floating));
      return;
    }
    final p = Palette.of(context);
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.zero),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.all(16), child: Text('Assign ${widget.name} to…', style: AppleTheme.headline(context))),
          ...courses.map((c) {
            final m = c as Map<String, dynamic>;
            return ListTile(
              leading: const Icon(CupertinoIcons.book, color: AppleColors.blue),
              title: Text(m['title']?.toString() ?? 'Course', style: AppleTheme.body(context)),
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  await widget.auth.apiPost('/api/v1/manage/courses/${m['id']}/enroll', {'email': widget.email});
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Assigned to ${m['title']}'), behavior: SnackBarBehavior.floating));
                } on ApiException catch (e) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating));
                } catch (_) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not assign'), behavior: SnackBarBehavior.floating));
                }
              },
            );
          }),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}


/// Per-course batch portal: shows the students of a course grouped by batch
/// (the unassigned queue first), resolved by the course's label.
class CourseBatchesScreen extends StatefulWidget {
  const CourseBatchesScreen({super.key, required this.auth, required this.courseId, required this.title});
  final AuthService auth;
  final String courseId;
  final String title;

  @override
  State<CourseBatchesScreen> createState() => _CourseBatchesScreenState();
}

class _CourseBatchesScreenState extends State<CourseBatchesScreen> {
  bool _loading = true;
  String _label = '';
  List<dynamic> _batches = [];
  int? _batchSize;
  bool _batchAuto = false;
  String? _err;

  // The unassigned (batch == null) students for this course are its live queue.
  List<dynamic> get _queue {
    for (final b in _batches) {
      if ((b as Map)['batch'] == null) return (b['students'] as List?) ?? [];
    }
    return const [];
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _err = null; });
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/courses/${widget.courseId}/batches');
      final data = ApiClient.decode(r);
      _label = data['label']?.toString() ?? '';
      _batches = (data['batches'] as List?) ?? [];
      final st = data['settings'] as Map?;
      _batchSize = (st?['batch_size'] is int) ? st!['batch_size'] as int : int.tryParse('${st?['batch_size'] ?? ''}');
      _batchAuto = st?['batch_auto'] == true;
    } catch (_) {
      _err = 'Could not load batches';
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  // Edit the per-course batch settings: default size + auto-allocation default.
  Future<void> _editSettings() async {
    final sizeCtrl = TextEditingController(text: _batchSize?.toString() ?? '');
    var auto = _batchAuto;
    final ok = await showFormSheet(context, square: true, title: 'Batch Settings — ${widget.title}',
        builder: (setS) => [
          Text('Defaults used when allocating this course\'s queue.', style: AppleTheme.footnote(context)),
          const SizedBox(height: 12),
          sheetField(sizeCtrl, 'Default students per batch', CupertinoIcons.number, keyboard: TextInputType.number),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text('Auto-allocate by default', style: AppleTheme.body(context))),
            CupertinoSwitch(value: auto, onChanged: (v) => setS(() => auto = v)),
          ]),
        ], onSubmit: () async {
      final size = int.tryParse(sizeCtrl.text.trim());
      if (sizeCtrl.text.trim().isNotEmpty && (size == null || size <= 0)) return 'Enter a valid batch size';
      try {
        await widget.auth.apiPatch('/api/v1/manage/courses/${widget.courseId}',
            {'batch_size': size ?? 0, 'batch_auto': auto});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Settings saved'); _load(); }
  }

  // Stamp all queued (unassigned) students with one batch code.
  Future<void> _createBatch() async {
    final queue = _queue;
    if (queue.isEmpty) { _toast('No unassigned students in the queue'); return; }
    String code = '';
    final ids = queue.map((s) => (s as Map)['id'].toString()).toList();
    final ok = await showFormSheet(context, square: true, title: 'Create Batch — ${widget.title}',
        builder: (setS) => [
          Text('${queue.length} unassigned student(s) in the queue — assign them a batch code.', style: AppleTheme.footnote(context)),
          const SizedBox(height: 12),
          BatchCodeField(onChanged: (v) => code = v),
        ], onSubmit: () async {
      if (code.trim().isEmpty) return 'Enter the full batch code';
      try {
        await widget.auth.apiPost('/api/v1/manage/users/batch-assign', {'user_ids': ids, 'batch': code.trim()});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Batch created'); _load(); }
  }

  // Move a student to a different batch code (leave blank to return to the queue).
  Future<void> _reassign(String userId, String name, dynamic current) async {
    String code = current?.toString() ?? '';
    final ok = await showFormSheet(context, square: true, title: 'Move — $name',
        builder: (_) => [
          Text('Batch code — leave blank to return to the queue', style: AppleTheme.footnote(context)),
          const SizedBox(height: 8),
          BatchCodeField(initial: current?.toString(), onChanged: (v) => code = v),
        ],
        onSubmit: () async {
      try {
        await widget.auth.apiPost('/api/v1/manage/users/$userId/batch', {'batch': code.trim()});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Student moved'); _load(); }
  }

  // Per-student hub inside a course — everything an admin needs for one student
  // here: move them to another batch, issue this course's certificate, or reset
  // their password.
  Future<void> _studentActions(Map<String, dynamic> s, dynamic batch) async {
    final userId = s['id'].toString();
    final name = s['name']?.toString() ?? 'Student';
    final v = await showSquareMenu(context, title: name, items: const [
      SquareMenuItem('Move to another batch', value: 'move', icon: CupertinoIcons.arrow_right_arrow_left),
      SquareMenuItem('Issue certificate', value: 'certificate', icon: CupertinoIcons.checkmark_seal),
      SquareMenuItem('Set / change password', value: 'password', icon: CupertinoIcons.lock),
    ]);
    if (v == 'move') _reassign(userId, name, batch);
    if (v == 'certificate') _issueCertificate(userId, name);
    if (v == 'password') _setPassword(userId, name);
  }

  // Issue this course's completion certificate to a single student.
  Future<void> _issueCertificate(String userId, String name) async {
    final yes = await showSquareConfirm(context,
        title: 'Issue certificate',
        message: 'Issue a "${widget.title}" completion certificate to $name?',
        confirmLabel: 'Issue');
    if (!yes) return;
    try {
      await widget.auth.apiPost('/api/v1/manage/courses/${widget.courseId}/certificates', {'user_ids': [userId]});
      _toast('Certificate issued');
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Could not issue certificate');
    }
  }

  // Set/change a student's login password (min 8 chars).
  Future<void> _setPassword(String userId, String name) async {
    final ctrl = TextEditingController();
    final ok = await showFormSheet(context, square: true, title: 'Set Password — $name',
        builder: (_) => [sheetField(ctrl, 'New password (min 8)', CupertinoIcons.lock, obscure: true)],
        onSubmit: () async {
      final pwd = ctrl.text.trim();
      if (pwd.length < 8) return 'Password must be at least 8 characters';
      try {
        await widget.auth.apiPost('/api/v1/manage/users/$userId/password', {'password': pwd});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) _toast('Password updated');
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SquareScope(child: Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(title: const Text('Batches'), backgroundColor: p.bg, elevation: 0),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                children: [
                  Text(widget.title, style: AppleTheme.largeTitle(context)),
                  Text(_label.isEmpty ? 'This course has no course label' : 'Course label · $_label',
                      style: AppleTheme.subhead(context)),
                  const SizedBox(height: 16),
                  if (_label.isNotEmpty) ...[
                    AppleCard(square: true, 
                      child: Row(children: [
                        const Icon(CupertinoIcons.slider_horizontal_3, size: 20),
                        const SizedBox(width: 10),
                        Expanded(child: Text(
                          'Default ${_batchSize == null ? '— ' : '$_batchSize '}per batch · ${_batchAuto ? 'Auto' : 'Manual'}',
                          style: AppleTheme.body(context),
                        )),
                        GestureDetector(
                          onTap: _editSettings,
                          behavior: HitTestBehavior.opaque,
                          child: Text('Settings', style: TextStyle(color: Palette.of(context).accent, fontWeight: FontWeight.w600)),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 10),
                    PrimaryButton(label: 'Create batch (${_queue.length})', icon: CupertinoIcons.square_stack_3d_up, square: true, onPressed: _createBatch),
                    const SizedBox(height: 18),
                  ],
                  if (_err != null) AppleCard(square: true, child: Text(_err!, style: AppleTheme.footnote(context)))
                  else if (_batches.isEmpty)
                    AppleCard(square: true, child: Text('No students in this course yet.', style: AppleTheme.footnote(context)))
                  else
                    ..._batches.map((b) => _batchGroup(b as Map<String, dynamic>)),
                ],
              ),
            ),
    ));
  }

  Widget _batchGroup(Map<String, dynamic> b) {
    final batch = b['batch'];
    final students = (b['students'] as List?) ?? [];
    final title = batch == null ? 'Queue · Unassigned (${students.length})' : 'Batch $batch (${students.length})';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(title),
      AppleCard(square: true, 
        padding: EdgeInsets.zero,
        child: Column(children: List.generate(students.length, (i) {
          final s = students[i] as Map<String, dynamic>;
          return Column(children: [
            if (i > 0) Divider(height: 1, indent: 56, color: Palette.of(context).separator),
            ListTile(
              leading: Avatar(name: s['name']?.toString() ?? '?', size: 36),
              title: Text(s['name']?.toString() ?? '', style: AppleTheme.body(context)),
              subtitle: Text(s['email']?.toString() ?? '', style: AppleTheme.footnote(context)),
              trailing: Icon(CupertinoIcons.ellipsis, size: 18, color: Palette.of(context).secondary),
              onTap: () => _studentActions(s, batch),
            ),
          ]);
        })),
      ),
      const SizedBox(height: 18),
    ]);
  }
}

/// Bottom sheet showing the original converted-lead record for a student.
class _LeadDetailSheet extends StatelessWidget {
  const _LeadDetailSheet({required this.name, required this.found, this.lead, this.error});
  final String name;
  final bool found;
  final Map<String, dynamic>? lead;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final l = lead;
    final children = <Widget>[
      Center(child: Text('Converted lead', style: AppleTheme.title2(context))),
      const SizedBox(height: 2),
      Center(child: Text(name, style: AppleTheme.footnote(context))),
      const SizedBox(height: 16),
    ];
    if (error != null) {
      children.add(Text(error!, style: AppleTheme.footnote(context)));
    } else if (!found || l == null) {
      children.add(Text('No converted-lead record found in the database for this student.',
          style: AppleTheme.footnote(context)));
    } else {
      for (final e in _fields(l)) {
        children.add(_row(context, e.key, e.value));
      }
      final record = l['record'];
      if (record is Map && record.isNotEmpty) {
        children.add(const SizedBox(height: 10));
        children.add(SectionHeader('Lead data'));
        final keys = record.keys.map((k) => k.toString()).toList()..sort();
        for (final k in keys) {
          final v = record[k];
          if (v == null || v.toString().trim().isEmpty || v.toString() == '{}' || v.toString() == '[]') continue;
          children.add(_row(context, k, v.toString()));
        }
      }
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        margin: const EdgeInsets.all(10),
        padding: const EdgeInsets.all(20),
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.zero),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ),
    );
  }

  // Top-level lead fields worth showing, in a sensible order, skipping blanks.
  List<MapEntry<String, String>> _fields(Map<String, dynamic> l) {
    String s(dynamic v) => v == null ? '' : v.toString();
    final pairs = <MapEntry<String, String>>[
      MapEntry('Status', s(l['status'])),
      MapEntry('Source', s(l['source'])),
      MapEntry('Campaign', s(l['campaign'])),
      MapEntry('Score', s(l['score'])),
      MapEntry('Owner', s(l['owner'])),
      MapEntry('Phone', s(l['phone'])),
      MapEntry('Email', s(l['email'])),
      MapEntry('Converted at', s(l['converted_at'])),
      MapEntry('Created at', s(l['created_at'])),
    ];
    return pairs.where((e) => e.value.trim().isNotEmpty).toList();
  }

  Widget _row(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 120, child: Text(label, style: AppleTheme.footnote(context))),
        const SizedBox(width: 10),
        Expanded(child: Text(value, style: AppleTheme.body(context))),
      ]),
    );
  }
}

/// Lists converted leads (from converted_leads_backup) grouped by course_id, with
/// a badge for whether each lead already has a student account.
class ConvertedLeadsScreen extends StatefulWidget {
  const ConvertedLeadsScreen({super.key, required this.auth});
  final AuthService auth;

  @override
  State<ConvertedLeadsScreen> createState() => _ConvertedLeadsScreenState();
}

class _ConvertedLeadsScreenState extends State<ConvertedLeadsScreen> {
  bool _loading = true;
  String? _err;
  List<dynamic> _leads = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _err = null; });
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/converted-leads');
      _leads = (ApiClient.decode(r)['leads'] as List?) ?? [];
    } catch (_) {
      _err = 'Could not load converted leads';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _delete(String leadId, String name) async {
    final yes = await showSquareConfirm(context,
        title: 'Delete converted lead',
        message: 'Remove "$name"? This also deletes the student account auto-created from it — along with their enrolment, progress and submissions. This cannot be undone.',
        confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/converted-leads/$leadId');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Deleted'), behavior: SnackBarBehavior.floating));
      _load();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not delete')));
    }
  }

  // Tap a lead → fetch and show every detail (scalar fields + the lead's raw
  // custom fields), the student login if provisioned, and a delete action.
  Future<void> _showDetail(Map<String, dynamic> lead) async {
    final id = lead['lead_id'].toString();
    Map<String, dynamic> d;
    try {
      d = ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/converted-leads/$id'));
    } catch (_) {
      d = Map<String, dynamic>.from(lead); // fall back to the row we already have
    }
    if (!mounted) return;

    String s(dynamic v) => (v == null || v.toString().trim().isEmpty) ? '' : v.toString();
    String dt(dynamic v) {
      final x = s(v);
      return x.isEmpty ? '' : x.replaceFirst('T', '  ').split('.').first;
    }
    final fields = <MapEntry<String, String>>[
      MapEntry('Phone', s(d['phone'])),
      MapEntry('Email', s(d['email'])),
      MapEntry('Status', s(d['status'])),
      if (d['score'] != null) MapEntry('Score', s(d['score'])),
      MapEntry('Source', s(d['source'])),
      MapEntry('Campaign', s(d['campaign'])),
      MapEntry('Owner', s(d['owner'])),
      MapEntry('Course', s(d['course_title'])),
      MapEntry('Course ID', s(d['course_id'])),
      MapEntry('Converted', dt(d['converted_at'])),
      MapEntry('Created', dt(d['created_at'])),
    ].where((e) => e.value.isNotEmpty).toList();

    // Flatten the record jsonb (custom fields, UTM, program, …) one level deep.
    final extra = <MapEntry<String, String>>[];
    void add(String k, dynamic v) {
      if (v == null) return;
      final val = v is List ? v.join(', ') : v.toString();
      if (val.trim().isEmpty || val == '{}' || val == '[]') return;
      extra.add(MapEntry(k, val));
    }
    final rec = d['record'];
    if (rec is Map) {
      rec.forEach((k, v) {
        if (v is Map) {
          v.forEach((k2, v2) => add(k2.toString(), v2));
        } else {
          add(k.toString(), v);
        }
      });
    }

    final prov = d['provisioned'] == true;
    final pwd = s(d['temp_password']);
    final loginId = s(d['phone']).isNotEmpty ? s(d['phone']) : s(d['email']);
    final name = s(d['name']).isNotEmpty ? s(d['name']) : '(no name)';

    await showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) {
        final p = Palette.of(ctx);
        Widget kv(String k, String v) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 104, child: Text(k, style: AppleTheme.footnote(ctx).copyWith(color: p.secondary))),
                Expanded(child: SelectableText(v, style: AppleTheme.body(ctx).copyWith(fontSize: 14))),
              ]),
            );
        return SquareScope(child: Container(
          margin: const EdgeInsets.all(10),
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          decoration: BoxDecoration(color: p.card),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 14, 10),
              child: Row(children: [
                Avatar(name: name, size: 44),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: AppleTheme.headline(ctx)),
                  Text(prov ? 'Has student account' : 'No account',
                      style: AppleTheme.footnote(ctx).copyWith(color: prov ? AppleColors.green : p.secondary, fontWeight: FontWeight.w600)),
                ])),
                GestureDetector(onTap: () => Navigator.pop(ctx), child: Icon(CupertinoIcons.xmark_circle_fill, size: 26, color: p.secondary)),
              ]),
            ),
            Divider(height: 1, color: p.separator),
            Flexible(child: ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 12), children: [
              if (pwd.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppleColors.green.withOpacity(0.10), border: Border.all(color: AppleColors.green.withOpacity(0.4))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('STUDENT LOGIN', style: AppleTheme.footnote(ctx).copyWith(color: AppleColors.green, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                    const SizedBox(height: 4),
                    SelectableText('Login: $loginId\nPassword: $pwd',
                        style: AppleTheme.body(ctx).copyWith(fontSize: 13, color: AppleColors.green, fontWeight: FontWeight.w600)),
                  ]),
                ),
                const SizedBox(height: 10),
              ],
              ...fields.map((e) => kv(e.key, e.value)),
              if (extra.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('LEAD FIELDS', style: AppleTheme.footnote(ctx).copyWith(fontWeight: FontWeight.w700, color: p.accent, letterSpacing: 0.5)),
                const SizedBox(height: 2),
                ...extra.map((e) => kv(e.key, e.value)),
              ],
            ])),
            Divider(height: 1, color: p.separator),
            Padding(
              padding: const EdgeInsets.all(12),
              child: GestureDetector(
                onTap: () { Navigator.pop(ctx); _delete(id, name); },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppleColors.red.withOpacity(0.12), border: Border.all(color: AppleColors.red.withOpacity(0.4))),
                  child: Row(mainAxisSize: MainAxisSize.min, children: const [
                    Icon(CupertinoIcons.trash, size: 16, color: AppleColors.red),
                    SizedBox(width: 6),
                    Text('Delete lead', style: TextStyle(color: AppleColors.red, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            ),
          ]),
        ));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // Group by course_id; un-tagged leads fall into a trailing "No course" group.
    final byCourse = <String, List<dynamic>>{};
    for (final l in _leads) {
      final cid = (l as Map)['course_id']?.toString().trim() ?? '';
      byCourse.putIfAbsent(cid, () => []).add(l);
    }
    final keys = byCourse.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty) return 1;
        if (b.isEmpty) return -1;
        return a.compareTo(b);
      });
    return SquareScope(child: Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(title: const Text('Converted Leads'), backgroundColor: p.bg, elevation: 0),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : RefreshIndicator(
              color: p.accent,
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                children: [
                  Text('Converted Leads', style: AppleTheme.largeTitle(context)),
                  Text('${_leads.length} total · grouped by course ID', style: AppleTheme.subhead(context)),
                  const SizedBox(height: 16),
                  // Leads with no course_id were never enrolled — set a course to
                  // enrol them, or delete the ones you don't need (trash icon).
                  if ((byCourse['']?.length ?? 0) > 0) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppleColors.orange.withOpacity(0.12),
                        border: Border(left: BorderSide(color: AppleColors.orange, width: 3)),
                      ),
                      child: Row(children: [
                        const Icon(CupertinoIcons.exclamationmark_triangle_fill, color: AppleColors.orange, size: 20),
                        const SizedBox(width: 10),
                        Expanded(child: Text(
                          '${byCourse['']!.length} lead${byCourse['']!.length == 1 ? '' : 's'} have no course_id, so they were never enrolled in a course. Set a course_id to enrol them, or delete the ones you don\'t need.',
                          style: AppleTheme.footnote(context),
                        )),
                      ]),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_err != null)
                    AppleCard(square: true, child: Text(_err!, style: AppleTheme.footnote(context)))
                  else if (_leads.isEmpty)
                    AppleCard(square: true, child: Text('No converted leads.', style: AppleTheme.footnote(context)))
                  else
                    ...keys.map((cid) => _courseGroup(cid, byCourse[cid]!)),
                ],
              ),
            ),
    ));
  }

  Widget _courseGroup(String cid, List<dynamic> leads) {
    final p = Palette.of(context);
    final accent = cid.isEmpty ? p.secondary : p.accent;
    final title = (leads.first as Map)['course_title']?.toString().trim() ?? '';
    final name = cid.isEmpty ? 'No course' : (title.isNotEmpty ? title : cid);
    final provisioned = leads.where((l) => (l as Map)['provisioned'] == true).length;
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(color: accent.withOpacity(0.05), border: Border.all(color: accent.withOpacity(0.35))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: accent.withOpacity(0.14), border: Border(left: BorderSide(color: accent, width: 3))),
          child: Row(children: [
            Icon(cid.isEmpty ? CupertinoIcons.question : CupertinoIcons.book_fill, color: accent, size: 22),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: AppleTheme.headline(context)),
              const SizedBox(height: 2),
              Text('${cid.isEmpty ? '' : 'ID: $cid · '}${leads.length} lead${leads.length == 1 ? '' : 's'} · $provisioned with account',
                  style: AppleTheme.footnote(context)),
            ])),
          ]),
        ),
        ...List.generate(leads.length, (i) {
          final l = leads[i] as Map<String, dynamic>;
          final prov = l['provisioned'] == true;
          final contact = [l['phone'], l['email']].where((x) => (x?.toString().trim().isNotEmpty ?? false)).join(' · ');
          final pwd = l['temp_password']?.toString().trim() ?? '';
          return Column(children: [
            if (i > 0) Divider(height: 1, indent: 16, color: p.separator),
            ListTile(
              onTap: () => _showDetail(l),
              leading: Avatar(name: l['name']?.toString() ?? '?', size: 36),
              title: Text(l['name']?.toString().trim().isNotEmpty == true ? l['name'].toString() : '(no name)', style: AppleTheme.body(context)),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(contact, style: AppleTheme.footnote(context), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (pwd.isNotEmpty)
                  Text('Login: ${l['phone']?.toString().trim().isNotEmpty == true ? l['phone'] : l['email']} · Pwd: $pwd',
                      style: AppleTheme.footnote(context).copyWith(color: AppleColors.green, fontWeight: FontWeight.w600),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: (prov ? AppleColors.green : p.secondary).withOpacity(0.15)),
                  child: Text(prov ? 'Student' : 'No account',
                      style: TextStyle(color: prov ? AppleColors.green : p.secondary, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => _delete(l['lead_id'].toString(),
                      l['name']?.toString().trim().isNotEmpty == true ? l['name'].toString() : 'this lead'),
                  behavior: HitTestBehavior.opaque,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red),
                  ),
                ),
              ]),
            ),
          ]);
        }),
      ]),
    );
  }
}

/// Course-scoped Study Hub editor — manage the Study Guides, Cheat Sheets, Mind
/// Map, Flashcards and Formula Sheets that enrolled students see in their Study
/// Hub. The Focus Timer is built-in and needs no content. Each card is one row
/// in study_materials; the shape of `items`/`body`/`note` depends on the kind.
class StudyHubEditorScreen extends StatefulWidget {
  const StudyHubEditorScreen({super.key, required this.auth, required this.courseId, required this.title});
  final AuthService auth;
  final String courseId;
  final String title;
  @override
  State<StudyHubEditorScreen> createState() => _StudyHubEditorScreenState();
}

class _StudyHubEditorScreenState extends State<StudyHubEditorScreen> {
  List<dynamic> _materials = [];
  bool _loading = true;
  String? _error;

  // The editable kinds, in display order: (id, label, icon).
  static const _kinds = <(String, String, IconData)>[
    ('guides', 'Study Guides', CupertinoIcons.book_fill),
    ('cheats', 'Cheat Sheets', CupertinoIcons.doc_text_fill),
    ('mindmap', 'Mind Map', CupertinoIcons.rectangle_3_offgrid_fill),
    ('flashcards', 'Flashcards', CupertinoIcons.rectangle_stack_fill),
    ('formulas', 'Formula Sheets', CupertinoIcons.function),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/courses/${widget.courseId}/study');
      final list = (ApiClient.decode(r)['materials'] as List?) ?? [];
      if (!mounted) return;
      setState(() { _materials = list; _loading = false; });
    } on ApiException catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.message; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = "Couldn't load Study Hub material — retry."; });
    }
  }

  List<Map<String, dynamic>> _of(String kind) => _materials
      .where((m) => (m as Map)['kind'] == kind)
      .map((m) => (m as Map).cast<String, dynamic>())
      .toList();

  List<String> _stringList(dynamic items) =>
      (items as List?)?.map((e) => e.toString()).toList() ?? const [];

  Future<void> _delete(String id) async {
    final yes = await showSquareConfirm(context,
        title: 'Delete', message: 'Remove this Study Hub card?', confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/study/$id');
      _load();
    } catch (_) {}
  }

  // A bordered multi-line text field for list/branch inputs.
  Widget _multiField(TextEditingController c, String hint, {int lines = 5}) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.zero),
      child: TextField(
        controller: c,
        minLines: lines,
        maxLines: lines + 4,
        style: AppleTheme.body(context),
        cursorColor: p.accent,
        decoration: InputDecoration(border: InputBorder.none, isDense: true, hintText: hint, hintStyle: AppleTheme.footnote(context)),
      ),
    );
  }

  Future<void> _form(String kind, [Map<String, dynamic>? edit]) async {
    final title = TextEditingController(text: edit?['title']?.toString() ?? '');
    final body = TextEditingController(text: edit?['body']?.toString() ?? '');
    final note = TextEditingController(text: edit?['note']?.toString() ?? '');
    final listCtrl = TextEditingController();
    final mindCtrl = TextEditingController();
    if (kind == 'guides' || kind == 'cheats') {
      listCtrl.text = _stringList(edit?['items']).join('\n');
    } else if (kind == 'mindmap') {
      final branches = (edit?['items'] as List?) ?? const [];
      mindCtrl.text = branches.map((b) {
        final m = b as Map;
        final leaves = (m['leaves'] as List?)?.map((e) => e.toString()).join(', ') ?? '';
        return '${m['name']}: $leaves';
      }).join('\n');
    }

    final ok = await showFormSheet(context, square: true, title: edit == null ? 'Add' : 'Edit', builder: (setS) {
      final f = <Widget>[];
      switch (kind) {
        case 'guides':
          f.addAll([
            sheetField(title, 'Topic title', CupertinoIcons.book),
            const SizedBox(height: 10),
            _label(context, 'Bullet points — one per line'),
            const SizedBox(height: 6),
            _multiField(listCtrl, 'Pipeline: ingestion → serving\nPick batch vs real-time'),
          ]);
          break;
        case 'cheats':
          f.addAll([
            sheetField(title, 'Heading', CupertinoIcons.doc_text),
            const SizedBox(height: 10),
            _label(context, 'Quick-reference items — one per line'),
            const SizedBox(height: 6),
            _multiField(listCtrl, 'RAG = retriever + LLM\nBatch vs streaming'),
          ]);
          break;
        case 'mindmap':
          f.addAll([
            sheetField(title, 'Centre concept', CupertinoIcons.smallcircle_circle),
            const SizedBox(height: 10),
            _label(context, 'Branches — one per line, as "Branch: leaf1, leaf2, leaf3"'),
            const SizedBox(height: 6),
            _multiField(mindCtrl, 'Data: Ingestion, Storage, Features\nServing: API, Batch, Cache'),
          ]);
          break;
        case 'flashcards':
          f.addAll([
            sheetField(title, 'Question (front)', CupertinoIcons.question_circle),
            const SizedBox(height: 10),
            _label(context, 'Answer (back)'),
            const SizedBox(height: 6),
            _multiField(body, 'The answer students see when they flip the card', lines: 3),
          ]);
          break;
        case 'formulas':
          f.addAll([
            sheetField(title, 'Name', CupertinoIcons.textformat),
            const SizedBox(height: 10),
            sheetField(body, 'Formula (e.g. F = m·a)', CupertinoIcons.function),
            const SizedBox(height: 10),
            sheetField(note, 'What it means', CupertinoIcons.text_alignleft),
          ]);
          break;
      }
      return f;
    }, onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      final payload = <String, dynamic>{
        'kind': kind,
        'title': title.text.trim(),
        'body': body.text.trim(),
        'note': note.text.trim(),
      };
      if (kind == 'guides' || kind == 'cheats') {
        payload['items'] = listCtrl.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else if (kind == 'mindmap') {
        final branches = <Map<String, dynamic>>[];
        for (final line in mindCtrl.text.split('\n')) {
          final t = line.trim();
          if (t.isEmpty) continue;
          final idx = t.indexOf(':');
          final name = idx >= 0 ? t.substring(0, idx).trim() : t;
          final leaves = idx >= 0
              ? t.substring(idx + 1).split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
              : <String>[];
          if (name.isNotEmpty) branches.add({'name': name, 'leaves': leaves});
        }
        payload['items'] = branches;
      }
      try {
        if (edit == null) {
          await widget.auth.apiPost('/api/v1/manage/courses/${widget.courseId}/study', payload);
        } else {
          await widget.auth.apiPatch('/api/v1/manage/study/${edit['id']}', payload);
        }
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) _load();
  }

  // Draft material with AI (Groq) — inserts drafts the admin can edit/delete.
  // Manual adding is unaffected.
  Future<void> _generate() async {
    final topic = TextEditingController();
    final count = TextEditingController(text: '5');
    int diff = 1;
    const diffs = ['easy', 'intermediate', 'hard'];
    final kinds = {for (final k in _kinds) k.$1: true}; // all selected by default
    final ok = await showFormSheet(context, square: true, title: 'Generate with AI', builder: (setS) {
      final p = Palette.of(context);
      return [
        Text('Type a topic — AI drafts study material you can edit or delete. Manual adding still works.', style: AppleTheme.footnote(context)),
        const SizedBox(height: 10),
        sheetField(topic, 'Topic or source material', CupertinoIcons.text_quote),
        const SizedBox(height: 10),
        sheetField(count, 'How many of each (1–12)', CupertinoIcons.number, keyboard: TextInputType.number),
        const SizedBox(height: 12),
        _label(context, 'Difficulty'),
        const SizedBox(height: 6),
        AppleSegmented(square: true, labels: const ['Easy', 'Medium', 'Hard'], selected: diff, onChanged: (i) => setS(() => diff = i)),
        const SizedBox(height: 12),
        _label(context, 'What to generate'),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final k in _kinds)
            GestureDetector(
              onTap: () => setS(() => kinds[k.$1] = !(kinds[k.$1] ?? false)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: (kinds[k.$1] ?? false) ? p.accent.withOpacity(0.14) : p.card2,
                  border: Border.all(color: (kinds[k.$1] ?? false) ? p.accent : p.separator),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon((kinds[k.$1] ?? false) ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                      size: 15, color: (kinds[k.$1] ?? false) ? p.accent : p.secondary),
                  const SizedBox(width: 6),
                  Text(k.$2, style: AppleTheme.footnote(context)),
                ]),
              ),
            ),
        ]),
      ];
    }, onSubmit: () async {
      if (topic.text.trim().isEmpty) return 'Enter a topic';
      final selected = kinds.entries.where((e) => e.value).map((e) => e.key).toList();
      if (selected.isEmpty) return 'Pick at least one type';
      try {
        await widget.auth.apiPost('/api/v1/manage/courses/${widget.courseId}/study/generate', {
          'topic': topic.text.trim(),
          'count': int.tryParse(count.text.trim()) ?? 5,
          'difficulty': diffs[diff],
          'kinds': selected,
        });
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Material generated ✓ — review & edit below'), behavior: SnackBarBehavior.floating));
      _load();
    }
  }

  // One-line summary of a card for its list row.
  String _summary(String kind, Map<String, dynamic> m) {
    switch (kind) {
      case 'guides':
        return '${_stringList(m['items']).length} points';
      case 'cheats':
        return '${_stringList(m['items']).length} items';
      case 'mindmap':
        return '${(m['items'] as List?)?.length ?? 0} branches';
      case 'flashcards':
        return m['body']?.toString() ?? '';
      case 'formulas':
        return m['body']?.toString() ?? '';
    }
    return '';
  }

  Widget _card(String kind, Map<String, dynamic> m) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppleCard(square: true,
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m['title']?.toString() ?? '', style: AppleTheme.body(context).copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(_summary(kind, m), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppleTheme.footnote(context)),
            ]),
          ),
          const SizedBox(width: 10),
          GestureDetector(onTap: () => _form(kind, m), child: Icon(CupertinoIcons.pencil, size: 18, color: p.secondary)),
          const SizedBox(width: 12),
          GestureDetector(onTap: () => _delete(m['id'].toString()), child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final w = MediaQuery.of(context).size.width;
    final hp = (w > 760 ? (w - 720) / 2 : 14.0).clamp(14, 400).toDouble();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(icon: const Icon(CupertinoIcons.chevron_left), onPressed: () => Navigator.pop(context)),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Study Hub material', style: AppleTheme.headline(context)),
          Text(widget.title, style: AppleTheme.footnote(context)),
        ]),
        actions: [
          IconButton(
            tooltip: 'Generate with AI',
            icon: Icon(CupertinoIcons.sparkles, color: p.accent),
            onPressed: _generate,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(hp, 12, hp, 40),
                children: [
                  if (_error != null)
                    AppleCard(square: true, child: Row(children: [
                      const Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 18, color: AppleColors.red),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_error!, style: AppleTheme.footnote(context).copyWith(color: AppleColors.red))),
                    ])),
                  AppleCard(square: true, child: Text(
                    'Edit what students see in this course’s Study Hub. The Focus Timer is always available — these sections add real content on top of it.',
                    style: AppleTheme.footnote(context))),
                  const SizedBox(height: 14),
                  for (final k in _kinds) ...[
                    Row(children: [
                      Icon(k.$3, size: 18, color: p.accent),
                      const SizedBox(width: 8),
                      Expanded(child: SectionHeader('${k.$2} (${_of(k.$1).length})')),
                      _addBtn(k.$1),
                    ]),
                    const SizedBox(height: 8),
                    if (_of(k.$1).isEmpty)
                      AppleCard(square: true, child: Text('Nothing yet — tap Add.', style: AppleTheme.footnote(context)))
                    else
                      ..._of(k.$1).map((m) => _card(k.$1, m)),
                    const SizedBox(height: 20),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _addBtn(String kind) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: () => _form(kind),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: p.accent.withOpacity(0.12), borderRadius: BorderRadius.zero),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(CupertinoIcons.add, size: 15, color: p.accent),
          const SizedBox(width: 4),
          Text('Add', style: TextStyle(color: p.accent, fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

/// Admin community manager — create/manage Discord-like communities (servers):
/// Global (everyone), Course-wise (enrolled), or Batch-wise (enrolled + batch),
/// each with channels. Mirrors the staff actions in the student forum.
class CommunitiesScreen extends StatefulWidget {
  const CommunitiesScreen({super.key, required this.auth});
  final AuthService auth;
  @override
  State<CommunitiesScreen> createState() => _CommunitiesScreenState();
}

class _CommunitiesScreenState extends State<CommunitiesScreen> {
  List<dynamic> _servers = [];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _err = null; });
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/community/servers');
      if (!mounted) return;
      setState(() { _servers = (ApiClient.decode(r)['servers'] as List?) ?? []; _loading = false; });
    } on ApiException catch (e) {
      if (mounted) setState(() { _loading = false; _err = e.message; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _err = "Couldn't load communities."; });
    }
  }

  List<Map<String, dynamic>> _of(String scope) =>
      _servers.where((s) => (s as Map)['scope'] == scope).map((s) => (s as Map).cast<String, dynamic>()).toList();

  Future<void> _createServer() async {
    final name = TextEditingController();
    final icon = TextEditingController();
    final batch = TextEditingController();
    int scope = 0; // 0 global, 1 course, 2 batch
    const scopes = ['global', 'course', 'batch'];
    List<dynamic> courses = [];
    String? courseId;
    try {
      courses = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/courses'))['courses'] as List?) ?? [];
    } catch (_) {}
    if (!mounted) return;
    final ok = await showFormSheet(context, square: true, title: 'New community', builder: (setS) => [
      sheetField(name, 'Community name (e.g. AI Architects)', CupertinoIcons.person_3_fill),
      const SizedBox(height: 10),
      sheetField(icon, 'Icon — an emoji or letter (optional)', CupertinoIcons.smiley),
      const SizedBox(height: 12),
      _label(context, 'Who has access'),
      const SizedBox(height: 6),
      AppleSegmented(square: true, labels: const ['Global (all)', 'Course', 'Batch'], selected: scope, onChanged: (i) => setS(() => scope = i)),
      const SizedBox(height: 6),
      _label(context, scope == 0
          ? 'Everyone on ONROL can see and post here.'
          : scope == 1
              ? 'Only students enrolled in the chosen course.'
              : 'Only students enrolled in the course AND in that batch.'),
      if (scope != 0) ...[
        const SizedBox(height: 12),
        _label(context, 'Course'),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in courses)
            GestureDetector(
              onTap: () => setS(() => courseId = c['id'].toString()),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: courseId == c['id'].toString() ? Palette.of(context).accent.withOpacity(0.16) : Palette.of(context).card2,
                  border: Border.all(color: courseId == c['id'].toString() ? Palette.of(context).accent : Palette.of(context).separator),
                ),
                child: Text(c['title']?.toString() ?? 'Course', style: AppleTheme.footnote(context)),
              ),
            ),
        ]),
      ],
      if (scope == 2) ...[
        const SizedBox(height: 12),
        sheetField(batch, 'Batch number (e.g. 1)', CupertinoIcons.number, keyboard: TextInputType.number),
      ],
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      if (scope != 0 && courseId == null) return 'Pick a course';
      if (scope == 2 && int.tryParse(batch.text.trim()) == null) return 'Batch number required';
      try {
        await widget.auth.apiPost('/api/v1/manage/community/servers', {
          'name': name.text.trim(),
          'scope': scopes[scope],
          'icon': icon.text.trim(),
          if (scope != 0) 'course_id': courseId,
          if (scope == 2) 'batch_number': int.parse(batch.text.trim()),
        });
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) _load();
  }

  Future<void> _addChannel(String serverId) async {
    final name = TextEditingController();
    final ok = await showFormSheet(context, square: true, title: 'New channel',
        builder: (_) => [sheetField(name, 'Channel name (e.g. announcements)', CupertinoIcons.number_circle)],
        onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      try {
        await widget.auth.apiPost('/api/v1/manage/community/servers/$serverId/channels', {'name': name.text.trim()});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) _load();
  }

  Future<void> _deleteServer(Map<String, dynamic> s) async {
    final yes = await showSquareConfirm(context,
        title: 'Delete community', message: 'Delete "${s['name']}" and all its channels & messages?',
        confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/community/servers/${s['id']}');
      _load();
    } catch (_) {}
  }

  Future<void> _deleteChannel(String id) async {
    try {
      await widget.auth.apiDelete('/api/v1/manage/community/channels/$id');
      _load();
    } catch (_) {}
  }

  Widget _smallButton(String label, IconData icon, VoidCallback onTap) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: p.accent.withOpacity(0.12), borderRadius: BorderRadius.zero),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: p.accent),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: p.accent, fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final w = MediaQuery.of(context).size.width;
    final hp = (w > 760 ? (w - 720) / 2 : 14.0).clamp(14, 400).toDouble();
    return SquareScope(child: Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg, elevation: 0, surfaceTintColor: Colors.transparent,
        title: Text('Communities', style: AppleTheme.headline(context)),
        actions: [IconButton(tooltip: 'New community', icon: Icon(CupertinoIcons.add_circled, color: p.accent), onPressed: _createServer)],
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(hp, 12, hp, 40),
                children: [
                  if (_err != null)
                    AppleCard(square: true, child: Text(_err!, style: AppleTheme.footnote(context).copyWith(color: AppleColors.red))),
                  AppleCard(square: true, child: Text(
                    'Communities are Discord-like servers with channels. Global is seen by everyone; Course and Batch are limited to who has access.',
                    style: AppleTheme.footnote(context))),
                  const SizedBox(height: 14),
                  for (final g in const [('global', 'Global'), ('course', 'Course-wise'), ('batch', 'Batch-wise')]) ...[
                    Row(children: [
                      Expanded(child: SectionHeader('${g.$2} (${_of(g.$1).length})')),
                      _smallButton('Add', CupertinoIcons.add, _createServer),
                    ]),
                    const SizedBox(height: 8),
                    if (_of(g.$1).isEmpty)
                      AppleCard(square: true, child: Text('None yet.', style: AppleTheme.footnote(context)))
                    else
                      ..._of(g.$1).map(_serverCard),
                    const SizedBox(height: 18),
                  ],
                ],
              ),
            ),
    ));
  }

  Widget _serverCard(Map<String, dynamic> s) {
    final p = Palette.of(context);
    final channels = (s['channels'] as List?) ?? [];
    final scope = s['scope']?.toString() ?? 'global';
    final sub = scope == 'global'
        ? 'Everyone'
        : scope == 'course'
            ? (s['course']?.toString().isNotEmpty == true ? s['course'].toString() : 'Course')
            : '${s['course'] ?? 'Course'} · Batch ${s['batch_number'] ?? ''}';
    final icon = s['icon']?.toString().trim() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppleCard(square: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 38, height: 38, alignment: Alignment.center,
              decoration: BoxDecoration(color: p.accent.withOpacity(0.12), borderRadius: BorderRadius.zero),
              child: Text(icon.isNotEmpty ? icon : (s['name']?.toString().isNotEmpty == true ? s['name'].toString()[0].toUpperCase() : '#'),
                  style: AppleTheme.headline(context).copyWith(color: p.accent)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s['name']?.toString() ?? 'Community', style: AppleTheme.headline(context)),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppleTheme.footnote(context)),
            ])),
            _smallButton('Channel', CupertinoIcons.add, () => _addChannel(s['id'].toString())),
            const SizedBox(width: 6),
            GestureDetector(onTap: () => _deleteServer(s), child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red)),
          ]),
          if (channels.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final ch in channels)
                Container(
                  padding: const EdgeInsets.only(left: 10, right: 4, top: 5, bottom: 5),
                  decoration: BoxDecoration(color: p.card2, border: Border.all(color: p.separator)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('#${(ch as Map)['name']}', style: AppleTheme.footnote(context)),
                    GestureDetector(
                      onTap: () => _deleteChannel(ch['id'].toString()),
                      child: const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(CupertinoIcons.xmark, size: 13, color: AppleColors.red)),
                    ),
                  ]),
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// A collapsible "Day" folder inside a module — tap the header to expand/collapse
/// its lessons. Open by default so nothing is hidden on first view.
class _DayFolder extends StatefulWidget {
  const _DayFolder({required this.label, required this.count, required this.children, this.trailing});
  final String label;
  final int count;
  final List<Widget> children;
  final Widget? trailing; // optional control in the header (e.g. day publish toggle)

  @override
  State<_DayFolder> createState() => _DayFolderState();
}

class _DayFolderState extends State<_DayFolder> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _open = !_open),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: p.accent.withOpacity(0.08), border: Border.all(color: p.separator)),
            child: Row(children: [
              Icon(_open ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_right, size: 12, color: p.accent),
              const SizedBox(width: 8),
              Icon(_open ? CupertinoIcons.folder_fill : CupertinoIcons.folder, size: 15, color: p.accent),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.label, style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w800, color: p.accent))),
              Text('${widget.count} ${widget.count == 1 ? 'item' : 'items'}', style: AppleTheme.footnote(context).copyWith(color: p.secondary)),
              if (widget.trailing != null) ...[const SizedBox(width: 10), widget.trailing!],
            ]),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open
              ? Padding(padding: const EdgeInsets.only(left: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children))
              : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }
}

/// Instructor grading queue for an assignment: lists each student's submission
/// (response text + link) and lets the instructor score + give feedback.
class _SubmissionsScreen extends StatefulWidget {
  const _SubmissionsScreen({required this.auth, required this.assessId, required this.title, required this.maxScore});
  final AuthService auth;
  final String assessId;
  final String title;
  final num maxScore;

  @override
  State<_SubmissionsScreen> createState() => _SubmissionsScreenState();
}

class _SubmissionsScreenState extends State<_SubmissionsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/assessments/${widget.assessId}/submissions'));
      _subs = ((m['submissions'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
    } catch (_) {}
  }

  Future<void> _downloadFile(Map<String, dynamic> f) async {
    try {
      final r = await widget.auth.apiGet('/api/v1/me/submission-files/${f['id']}');
      saveFileBytes(f['filename']?.toString() ?? 'file', '', r.bodyBytes);
    } catch (_) {}
  }

  Future<void> _grade(Map<String, dynamic> s) async {
    final p = Palette.of(context);
    final score = TextEditingController(text: (s['score'] as num?)?.toString() ?? '');
    final feedback = TextEditingController(text: s['feedback']?.toString() ?? '');
    final body = s['body']?.toString() ?? '';
    final link = s['link']?.toString() ?? '';
    final files = ((s['files'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    final ok = await showFormSheet(context, square: true, big: true, title: 'Grade — ${s['student'] ?? 'Student'}', builder: (_) => [
      if (body.isNotEmpty) ...[
        Text('Response', style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: p.card2, border: Border.all(color: p.separator)),
          child: Text(body, style: AppleTheme.body(context).copyWith(fontSize: 14, height: 1.4)),
        ),
        const SizedBox(height: 12),
      ],
      if (files.isNotEmpty) ...[
        Text('Files', style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        ...files.map((f) => GestureDetector(
              onTap: () => _downloadFile(f),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Icon(CupertinoIcons.doc_fill, size: 16, color: p.accent),
                  const SizedBox(width: 8),
                  Expanded(child: Text(f['filename']?.toString() ?? 'file', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppleTheme.body(context).copyWith(fontSize: 13, color: p.accent))),
                  Icon(CupertinoIcons.cloud_download, size: 16, color: p.secondary),
                ]),
              ),
            )),
        const SizedBox(height: 12),
      ],
      if (link.isNotEmpty) ...[
        GestureDetector(
          onTap: () => _openLink(link),
          child: Row(children: [
            Icon(CupertinoIcons.link, size: 15, color: p.accent),
            const SizedBox(width: 6),
            Expanded(child: Text(link, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppleTheme.body(context).copyWith(fontSize: 13, color: p.accent))),
          ]),
        ),
        const SizedBox(height: 12),
      ],
      sheetField(score, 'Score (out of ${widget.maxScore.round()})', CupertinoIcons.number, keyboard: const TextInputType.numberWithOptions(decimal: true)),
      const SizedBox(height: 10),
      sheetField(feedback, 'Feedback (optional)', CupertinoIcons.text_bubble),
    ], onSubmit: () async {
      final sc = double.tryParse(score.text.trim());
      if (sc == null) return 'Enter a score';
      await widget.auth.apiPost('/api/v1/manage/submissions/${s['id']}/grade', {'score': sc, 'feedback': feedback.text.trim()});
      return null;
    });
    if (ok == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.card,
        foregroundColor: p.label,
        elevation: 0,
        title: Text(widget.title, style: AppleTheme.headline(context)),
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : _subs.isEmpty
              ? Center(child: Text('No submissions yet.', style: AppleTheme.footnote(context)))
              : ListView.separated(
                  padding: const EdgeInsets.all(14),
                  itemCount: _subs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _card(_subs[i]),
                ),
    );
  }

  Widget _card(Map<String, dynamic> s) {
    final p = Palette.of(context);
    final graded = s['status'] == 'graded';
    final body = s['body']?.toString() ?? '';
    final link = s['link']?.toString() ?? '';
    final fileCount = ((s['files'] as List?) ?? []).length;
    return AppleCard(
      square: true,
      onTap: () => _grade(s),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(s['student']?.toString() ?? 'Student', style: AppleTheme.headline(context))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(color: (graded ? AppleColors.green : AppleColors.blue).withOpacity(0.14)),
            child: Text(
              graded ? 'Graded · ${(s['score'] as num?)?.round() ?? 0}/${widget.maxScore.round()}' : 'Submitted',
              style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700, color: graded ? AppleColors.green : AppleColors.blue),
            ),
          ),
        ]),
        if (body.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(body, maxLines: 4, overflow: TextOverflow.ellipsis, style: AppleTheme.body(context).copyWith(fontSize: 13, color: p.secondary)),
        ],
        if (link.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(children: [
            Icon(CupertinoIcons.link, size: 14, color: p.accent),
            const SizedBox(width: 6),
            Expanded(child: Text(link, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppleTheme.body(context).copyWith(fontSize: 12.5, color: p.accent))),
          ]),
        ],
        if (fileCount > 0) ...[
          const SizedBox(height: 6),
          Row(children: [
            Icon(CupertinoIcons.paperclip, size: 14, color: p.secondary),
            const SizedBox(width: 6),
            Text('$fileCount file${fileCount == 1 ? '' : 's'}', style: AppleTheme.footnote(context).copyWith(color: p.secondary)),
          ]),
        ],
        const SizedBox(height: 8),
        Row(children: [
          Icon(CupertinoIcons.pencil, size: 14, color: p.accent),
          const SizedBox(width: 4),
          Text(graded ? 'Update grade' : 'Grade', style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700, color: p.accent)),
        ]),
      ]),
    );
  }
}
