import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/profile_view.dart';
import '../widgets/ui.dart';
import 'discussion_screen.dart';
import 'login_screen.dart';

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

  bool get _isAdmin => widget.auth.user?.role == 'manager' || widget.auth.user?.role == 'superadmin';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/courses');
      _courses = (ApiClient.decode(r)['courses'] as List?) ?? [];
      final q = await widget.auth.apiGet('/api/v1/manage/enrollment-requests');
      _requests = (ApiClient.decode(q)['requests'] as List?) ?? [];
      if (_isAdmin) {
        final u = await widget.auth.apiGet('/api/v1/manage/users');
        _people = (ApiClient.decode(u)['users'] as List?) ?? [];
      }
    } catch (_) {}
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
    final yes = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete course'),
        content: Text('Delete "$title" and all its content permanently? This cannot be undone. Consider archiving instead.'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/courses/$courseId');
      _toast('Course deleted');
      _load();
    } catch (_) {
      _toast('Could not delete');
    }
  }

  // Archive / restore / delete a course via an action sheet.
  void _courseMenu(Map<String, dynamic> c) {
    final id = c['id'].toString();
    final title = c['title']?.toString() ?? 'Course';
    final archived = (c['status']?.toString() ?? '') == 'archived';
    showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(title),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () { Navigator.pop(ctx); archived ? _setCourseStatus(id, 'draft') : _setCourseStatus(id, 'archived'); },
            child: Text(archived ? 'Restore to draft' : 'Archive course'),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () { Navigator.pop(ctx); _deleteCourse(id, title); },
            child: const Text('Delete course'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      ),
    );
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
      const NavDest(CupertinoIcons.person_fill, 'Profile'),
    ];
    final pages = <Widget>[
      _consolePage(),
      if (_isAdmin) _peoplePage(),
      _profilePage(),
    ];
    return AppShell(
      auth: widget.auth,
      onSignOut: _logout,
      trailing: _isAdmin ? _newCourseButton() : null,
      destinations: dests,
      pages: pages,
    );
  }

  Widget _peoplePage() {
    final hp = _hPad(context);
    final instructors = _people.where((u) => u['role'] == 'instructor').toList();
    final students = _people.where((u) => u['role'] == 'student').toList();
    final others = _people.where((u) => u['role'] == 'manager' || u['role'] == 'superadmin').toList();
    return ListView(
      padding: EdgeInsets.fromLTRB(hp, 18, hp, 40),
      children: [
        Text('People', style: AppleTheme.largeTitle(context)),
        Text('Create and manage accounts', style: AppleTheme.subhead(context)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: PrimaryButton(label: 'Add Instructor', icon: CupertinoIcons.person_badge_plus, square: true, onPressed: () => _addPerson('instructor'))),
          const SizedBox(width: 12),
          Expanded(child: PrimaryButton(label: 'Add Student', icon: CupertinoIcons.person_add, square: true, onPressed: () => _addPerson('student'))),
        ]),
        const SizedBox(height: 12),
        PrimaryButton(label: 'Send Announcement', icon: CupertinoIcons.speaker_2_fill, square: true, onPressed: _sendAnnouncement),
        const SizedBox(height: 22),
        if (others.isNotEmpty) ...[_peopleGroup('Admins', others), const SizedBox(height: 18)],
        _peopleGroup('Instructors (${instructors.length})', instructors),
        const SizedBox(height: 18),
        // Students divided by batch number.
        ..._studentsByBatch(students),
      ],
    );
  }

  // Groups students into "Batch N" sections (and "Unassigned"), sorted.
  List<Widget> _studentsByBatch(List<dynamic> students) {
    final byBatch = <int?, List<dynamic>>{};
    for (final s in students) {
      final b = (s['batch'] is int) ? s['batch'] as int : int.tryParse('${s['batch'] ?? ''}');
      byBatch.putIfAbsent(b, () => []).add(s);
    }
    final keys = byBatch.keys.toList()
      ..sort((a, b) => (a ?? 1 << 30).compareTo(b ?? 1 << 30));
    final out = <Widget>[];
    for (final k in keys) {
      final list = byBatch[k]!;
      out.add(_peopleGroup(k == null ? 'Students · Unassigned (${list.length})' : 'Students · Batch $k (${list.length})', list, batch: true));
      out.add(const SizedBox(height: 18));
    }
    if (out.isEmpty) out.add(_peopleGroup('Students (0)', const [], batch: true));
    return out;
  }

  Widget _peopleGroup(String title, List<dynamic> people, {bool batch = false}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(title),
      if (people.isEmpty)
        AppleCard(child: Text('None yet.', style: AppleTheme.footnote(context)))
      else
        AppleCard(
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
                    GestureDetector(
                      onTap: () => _setBatch(u['id'].toString(), u['full_name']?.toString() ?? 'Student', (u['batch'] is int) ? u['batch'] as int : int.tryParse('${u['batch'] ?? ''}')),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: Palette.of(context).accent.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                        child: Text(
                          u['batch'] == null ? 'Set batch' : 'Batch ${u['batch']}',
                          style: TextStyle(color: Palette.of(context).accent, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Icon(CupertinoIcons.device_phone_portrait, color: Palette.of(context).accent, size: 20),
                ]),
              ),
            ]);
          })),
        ),
    ]);
  }

  // Assign a student to a batch number (blank/0 clears it).
  Future<void> _setBatch(String userId, String name, int? current) async {
    final ctrl = TextEditingController(text: current?.toString() ?? '');
    final ok = await showFormSheet(context, title: 'Set Batch — $name',
        builder: (_) => [sheetField(ctrl, 'Batch number (blank to clear)', CupertinoIcons.number)],
        onSubmit: () async {
      final n = int.tryParse(ctrl.text.trim());
      try {
        await widget.auth.apiPost('/api/v1/manage/users/$userId/batch', {'batch': n});
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

  // Broadcast an announcement to everyone, a batch, or a role.
  Future<void> _sendAnnouncement() async {
    final title = TextEditingController();
    final body = TextEditingController();
    final batch = TextEditingController();
    int audience = 0; // 0=all, 1=batch, 2=role
    int role = 0; // student, instructor, manager
    const roles = ['student', 'instructor', 'manager'];
    final ok = await showFormSheet(context, title: 'Send Announcement', builder: (setS) => [
      sheetField(title, 'Title', CupertinoIcons.textformat),
      const SizedBox(height: 10),
      sheetField(body, 'Message', CupertinoIcons.text_alignleft),
      const SizedBox(height: 12),
      Text('Audience', style: AppleTheme.footnote(context)),
      const SizedBox(height: 6),
      AppleSegmented(labels: const ['Everyone', 'Batch', 'Role'], selected: audience, onChanged: (i) => setS(() => audience = i)),
      if (audience == 1) ...[
        const SizedBox(height: 10),
        sheetField(batch, 'Batch number', CupertinoIcons.number, keyboard: TextInputType.number),
      ],
      if (audience == 2) ...[
        const SizedBox(height: 10),
        AppleSegmented(labels: const ['Students', 'Instructors', 'Managers'], selected: role, onChanged: (i) => setS(() => role = i)),
      ],
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      final payload = <String, dynamic>{
        'title': title.text.trim(),
        'body': body.text.trim(),
        'audience': audience == 0 ? 'all' : (audience == 1 ? 'batch' : 'role'),
      };
      if (audience == 1) {
        final n = int.tryParse(batch.text.trim());
        if (n == null) return 'Enter a batch number';
        payload['batch_number'] = n;
      }
      if (audience == 2) payload['role'] = roles[role];
      try {
        await widget.auth.apiPost('/api/v1/manage/announcements', payload);
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) _toast('Announcement sent');
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
    final pass = TextEditingController();
    final ok = await showFormSheet(context, title: role == 'instructor' ? 'Add Instructor' : 'Add Student', builder: (_) => [
      sheetField(name, 'Full name', CupertinoIcons.person),
      const SizedBox(height: 10),
      sheetField(email, 'Email', CupertinoIcons.mail),
      const SizedBox(height: 10),
      sheetField(username, 'Username (optional — for sign-in)', CupertinoIcons.at),
      const SizedBox(height: 10),
      sheetField(pass, 'Temporary password (min 8)', CupertinoIcons.lock),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty || email.text.trim().isEmpty) return 'Name and email required';
      if (pass.text.trim().length < 8) return 'Password must be at least 8 characters';
      try {
        await widget.auth.apiPost('/api/v1/manage/users', {
          'full_name': name.text.trim(),
          'email': email.text.trim(),
          if (username.text.trim().isNotEmpty) 'username': username.text.trim(),
          'password': pass.text.trim(),
          'role': role,
        });
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      _toast('${role == 'instructor' ? 'Instructor' : 'Student'} created');
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
          borderRadius: BorderRadius.circular(6),
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
            AppleCard(
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
      child: AppleCard(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => CourseEditorScreen(auth: widget.auth, courseId: c['id'].toString(), title: c['title'].toString()),
        )).then((_) => _load()),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: AppleColors.blue.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
            child: const Icon(CupertinoIcons.book_fill, color: AppleColors.blue, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c['title']?.toString() ?? 'Course', style: AppleTheme.headline(context)),
              const SizedBox(height: 2),
              Text('${c['enroll_type'] ?? ''} enrollment', style: AppleTheme.footnote(context)),
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
          // Archive / delete actions.
          GestureDetector(
            onTap: () => _courseMenu(c),
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(CupertinoIcons.ellipsis_vertical, size: 20, color: Palette.of(context).secondary),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _requestCard(Map<String, dynamic> r) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppleCard(
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: AppleColors.orange.withOpacity(0.14), borderRadius: BorderRadius.circular(11)),
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
    final desc = TextEditingController();
    final imageUrl = TextEditingController();
    String? imageData; // uploaded data URI (takes priority over the URL field)
    int enrollType = 0; // self, manual
    String instructorId = instructors.first['id'].toString();

    final created = await showFormSheet(
      context,
      title: 'New Course',
      builder: (setS) => [
        sheetField(title, 'Course title', CupertinoIcons.textformat),
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
        AppleSegmented(labels: const ['Self-enroll', 'Manual'], selected: enrollType, onChanged: (i) => setS(() => enrollType = i)),
      ],
      onSubmit: () async {
        if (title.text.trim().isEmpty) return 'Title is required';
        try {
          final image = imageData ?? (imageUrl.text.trim().isNotEmpty ? imageUrl.text.trim() : null);
          await widget.auth.apiPost('/api/v1/manage/courses', {
            'title': title.text.trim(),
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
    final batch = TextEditingController();
    final ok = await showFormSheet(context, title: 'Issue by batch',
        builder: (_) => [sheetField(batch, 'Batch number (e.g. 1)', CupertinoIcons.number, keyboard: TextInputType.number)],
        onSubmit: () async {
      final n = int.tryParse(batch.text.trim());
      if (n == null) return 'Enter a batch number';
      return null;
    });
    if (ok == true) {
      final n = int.tryParse(batch.text.trim());
      if (n != null) _issue({'batch': n}, 'batch $n');
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
                        decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(8)),
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
                  AppleCard(child: Text('No students enrolled yet.', style: AppleTheme.footnote(context)))
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
      child: AppleCard(
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
  const _QuizBuilder({required this.auth, required this.assessmentId, required this.title});
  final AuthService auth;
  final String assessmentId;
  final String title;
  @override
  State<_QuizBuilder> createState() => _QuizBuilderState();
}

class _QuizBuilderState extends State<_QuizBuilder> {
  List<dynamic> _questions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/assessments/${widget.assessmentId}/questions');
      _questions = (ApiClient.decode(r)['questions'] as List?) ?? [];
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _delete(String id) async {
    try {
      await widget.auth.apiDelete('/api/v1/manage/questions/$id');
      _load();
    } catch (_) {}
  }

  Future<void> _add() async {
    final prompt = TextEditingController();
    final points = TextEditingController(text: '1');
    final shortAns = TextEditingController();
    final opts = <TextEditingController>[TextEditingController(), TextEditingController()];
    int type = 0; // mcq, truefalse, short
    int correctIdx = 0; // for mcq + truefalse
    const types = ['mcq', 'truefalse', 'short'];

    final ok = await showFormSheet(context, title: 'Add Question', builder: (setS) {
      final rows = <Widget>[
        sheetField(prompt, 'Question prompt', CupertinoIcons.text_quote),
        const SizedBox(height: 10),
        AppleSegmented(labels: const ['MCQ', 'True/False', 'Short'], selected: type, onChanged: (i) => setS(() {
          type = i;
          correctIdx = 0;
        })),
        const SizedBox(height: 12),
      ];
      if (type == 0) {
        rows.add(_label(context, 'Options — tap the circle to mark the correct one'));
        rows.add(const SizedBox(height: 6));
        for (var i = 0; i < opts.length; i++) {
          rows.add(Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              GestureDetector(
                onTap: () => setS(() => correctIdx = i),
                child: Icon(correctIdx == i ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                    color: correctIdx == i ? AppleColors.green : Palette.of(context).secondary, size: 24),
              ),
              const SizedBox(width: 10),
              Expanded(child: sheetField(opts[i], 'Option ${i + 1}', CupertinoIcons.circle_grid_hex)),
              if (opts.length > 2) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => setS(() {
                    opts.removeAt(i);
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
      } else if (type == 1) {
        rows.add(_label(context, 'Correct answer'));
        rows.add(const SizedBox(height: 6));
        rows.add(AppleSegmented(labels: const ['True', 'False'], selected: correctIdx, onChanged: (i) => setS(() => correctIdx = i)));
      } else {
        rows.add(sheetField(shortAns, 'Correct answer', CupertinoIcons.checkmark_alt_circle));
      }
      rows.add(const SizedBox(height: 12));
      rows.add(sheetField(points, 'Points', CupertinoIcons.number, keyboard: TextInputType.number));
      return rows;
    }, onSubmit: () async {
      if (prompt.text.trim().isEmpty) return 'Prompt required';
      List<String> options;
      String correct;
      if (type == 0) {
        options = opts.map((c) => c.text.trim()).where((s) => s.isNotEmpty).toList();
        if (options.length < 2) return 'Add at least two options';
        if (correctIdx >= options.length) return 'Pick the correct option';
        correct = options[correctIdx];
      } else if (type == 1) {
        options = ['true', 'false'];
        correct = correctIdx == 0 ? 'true' : 'false';
      } else {
        options = [];
        correct = shortAns.text.trim();
      }
      try {
        await widget.auth.apiPost('/api/v1/manage/assessments/${widget.assessmentId}/questions', {
          'prompt': prompt.text.trim(),
          'type': types[type],
          'options': options,
          'correct': correct,
          'points': double.tryParse(points.text.trim()) ?? 1,
        });
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
          Text('Quiz builder', style: AppleTheme.headline(context)),
          Text(widget.title, style: AppleTheme.footnote(context)),
        ]),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: p.accent,
        onPressed: _add,
        icon: const Icon(CupertinoIcons.add, color: Colors.white),
        label: const Text('Add question', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(hp, 12, hp, 96),
              children: [
                if (_questions.isEmpty)
                  AppleCard(child: Text('No questions yet. Tap “Add question” to build this quiz.', style: AppleTheme.footnote(context)))
                else
                  ..._questions.asMap().entries.map((e) => _questionCard(e.key + 1, e.value as Map<String, dynamic>)),
              ],
            ),
    );
  }

  Widget _questionCard(int n, Map<String, dynamic> q) {
    final options = (q['options'] as List?) ?? [];
    final type = q['type']?.toString() ?? 'mcq';
    final correct = q['correct']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppleCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text('$n. ${q['prompt'] ?? ''}', style: AppleTheme.body(context).copyWith(fontWeight: FontWeight.w700))),
            Text('${q['points'] ?? 1} pt', style: AppleTheme.footnote(context)),
            const SizedBox(width: 8),
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
        ClipRRect(borderRadius: BorderRadius.circular(10), child: pic),
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
              decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.circular(8)),
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
        decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.circular(8)),
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
        final d = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: DateTime.now().subtract(const Duration(days: 1)),
          lastDate: DateTime.now().add(const Duration(days: 365)),
        );
        if (d == null) return;
        final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(value));
        if (t == null) return;
        onPick(DateTime(d.year, d.month, d.day, t.hour, t.minute));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.circular(12)),
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
        decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.circular(12)),
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
        decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(13)),
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
                AppleCard(
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
                const SizedBox(height: 14),
                // Admission control — how students get into this course.
                AppleCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(CupertinoIcons.person_2_fill, color: AppleColors.blue, size: 22),
                      const SizedBox(width: 10),
                      Text('Admission', style: AppleTheme.headline(context)),
                    ]),
                    const SizedBox(height: 12),
                    AppleSegmented(labels: _admLabels, selected: admIndex, onChanged: (i) => _setAdmission(_admModes[i])),
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
                  AppleCard(child: Text('No modules yet. Add one, then add lessons inside it.', style: AppleTheme.footnote(context)))
                else
                  ...modules.map((m) => _moduleCard(m as Map<String, dynamic>)),

                const SizedBox(height: 22),
                Row(children: [
                  Expanded(child: SectionHeader('Live Classes (${_sessions.length})')),
                  _smallButton('Add', CupertinoIcons.videocam_fill, _addSession),
                ]),
                if (_sessions.isEmpty)
                  AppleCard(child: Text('No live classes scheduled. Add one — enrolled students will see it and can join.', style: AppleTheme.footnote(context)))
                else
                  ..._sessions.map((s) => _sessionCard(s as Map<String, dynamic>)),

                const SizedBox(height: 22),
                Row(children: [
                  Expanded(child: SectionHeader('Quizzes & Assignments (${_assessments.length})')),
                  _smallButton('Add', CupertinoIcons.doc_text_fill, _addAssignment),
                ]),
                if (_assessments.isEmpty)
                  AppleCard(child: Text('None yet. Add a quiz or assignment — students submit and you grade.', style: AppleTheme.footnote(context)))
                else
                  ..._assessmentsByDay(),

                const SizedBox(height: 22),
                PrimaryButton(
                  label: 'Doubts & Discussion',
                  icon: CupertinoIcons.chat_bubble_2_fill,
                  square: true,
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DiscussionScreen(auth: widget.auth, courseId: widget.courseId, title: widget.title))),
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
                  AppleCard(child: Text('No students enrolled yet.', style: AppleTheme.footnote(context)))
                else
                  AppleCard(
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
    final hasLink = (s['join_url']?.toString() ?? '').isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => _editSession(s),
        behavior: HitTestBehavior.opaque,
        child: AppleCard(
          child: Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(color: AppleColors.red.withOpacity(0.12), borderRadius: BorderRadius.circular(11)),
              child: const Icon(CupertinoIcons.videocam_fill, color: AppleColors.red, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s['title']?.toString() ?? 'Live class', style: AppleTheme.headline(context)),
                Text(hasLink ? _fmtTime(s['starts_at']?.toString()) : '${_fmtTime(s['starts_at']?.toString())} · No link — tap to add',
                    style: AppleTheme.footnote(context)),
              ]),
            ),
            _smallButton('Edit link', CupertinoIcons.link, () => _editSession(s)),
            const SizedBox(width: 6),
            Icon(hasLink ? CupertinoIcons.link : CupertinoIcons.exclamationmark_circle,
                size: 18, color: hasLink ? p.secondary : AppleColors.orange),
          ]),
        ),
      ),
    );
  }

  // Update a live session's video (join) link — and optionally its title.
  Future<void> _editSession(Map<String, dynamic> s) async {
    final title = TextEditingController(text: s['title']?.toString() ?? '');
    final url = TextEditingController(text: s['join_url']?.toString() ?? '');
    final ok = await showFormSheet(context, title: 'Update Live Link', builder: (setS) => [
      sheetField(title, 'Title', CupertinoIcons.textformat),
      const SizedBox(height: 10),
      sheetField(url, 'Live link (Zoho / Meet / Jitsi URL)', CupertinoIcons.link),
    ], onSubmit: () async {
      if (url.text.trim().isEmpty) return 'Live link required';
      try {
        await widget.auth.apiPatch('/api/v1/manage/sessions/${s['id']}', {
          'title': title.text.trim(),
          'join_url': url.text.trim(),
        });
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      _toast('Live link updated');
      _load();
    }
  }

  Future<void> _addAssignment({String? moduleId, String? moduleTitle}) async {
    final title = TextEditingController();
    final maxScore = TextEditingController(text: '100');
    final day = TextEditingController();
    int type = 0; // assignment, quiz
    DateTime due = DateTime.now().add(const Duration(days: 7));
    final ok = await showFormSheet(context, title: moduleId == null ? 'Add Assignment' : 'Add to "${moduleTitle ?? 'Module'}"', builder: (setS) => [
      sheetField(title, 'Title (e.g. Assignment 1)', CupertinoIcons.doc_text),
      const SizedBox(height: 10),
      AppleSegmented(labels: const ['Assignment', 'Quiz'], selected: type, onChanged: (i) => setS(() => type = i)),
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

  // Group assessments under "Day N" headers (day-less ones fall under "Unscheduled").
  List<Widget> _assessmentsByDay() {
    final groups = <int?, List<Map<String, dynamic>>>{};
    for (final a in _assessments) {
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
    final out = <Widget>[];
    for (final k in keys) {
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(k == null ? 'Unscheduled' : 'Day $k',
            style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700)),
      ));
      out.addAll(groups[k]!.map(_assessmentCard));
    }
    return out;
  }

  Widget _assessmentCard(Map<String, dynamic> a) {
    final isQuiz = a['type'] == 'quiz';
    final qCount = a['questions'] ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppleCard(
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: (isQuiz ? AppleColors.purple : AppleColors.blue).withOpacity(0.12), borderRadius: BorderRadius.circular(11)),
            child: Icon(isQuiz ? CupertinoIcons.question_square_fill : CupertinoIcons.doc_text_fill, color: isQuiz ? AppleColors.purple : AppleColors.blue, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a['title']?.toString() ?? 'Assessment', style: AppleTheme.headline(context)),
              Text('${isQuiz ? 'Quiz' : 'Assignment'} · ${a['max_score'] ?? 100} pts${isQuiz ? ' · $qCount questions' : ''}', style: AppleTheme.footnote(context)),
            ]),
          ),
          if (isQuiz) _smallButton('Build', CupertinoIcons.slider_horizontal_3, () => _openQuizBuilder(a['id'].toString(), a['title']?.toString() ?? 'Quiz')),
        ]),
      ),
    );
  }

  // Open the full quiz builder (list questions, add with real options + correct
  // selection, delete). Reloads the course on return so question counts refresh.
  Future<void> _openQuizBuilder(String assessmentId, String title) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _QuizBuilder(auth: widget.auth, assessmentId: assessmentId, title: title)));
    _load();
  }

  Future<void> _addSession() async {
    final title = TextEditingController();
    final url = TextEditingController();
    DateTime when = DateTime.now().add(const Duration(hours: 1));
    final ok = await showFormSheet(context, title: 'Add Live Class', builder: (setS) => [
      sheetField(title, 'Title (e.g. Lecture 1)', CupertinoIcons.textformat),
      const SizedBox(height: 10),
      sheetField(url, 'Live link (Zoho / Meet / Jitsi URL)', CupertinoIcons.link),
      const SizedBox(height: 12),
      _DateTimeRow(value: when, onPick: (d) => setS(() => when = d)),
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      if (url.text.trim().isEmpty) return 'Live link required';
      try {
        await widget.auth.apiPost('/api/v1/manage/courses/${widget.courseId}/sessions', {
          'title': title.text.trim(),
          'join_url': url.text.trim(),
          'starts_at': when.toUtc().toIso8601String(),
        });
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

  Widget _moduleCard(Map<String, dynamic> m) {
    final lessons = (m['lessons'] as List?) ?? [];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppleCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(m['title']?.toString() ?? 'Module', style: AppleTheme.headline(context))),
            _smallButton('Lesson', CupertinoIcons.add, () => _addLesson(m['id'].toString())),
            const SizedBox(width: 6),
            _smallButton('Quiz', CupertinoIcons.doc_text_fill, () => _addAssignment(moduleId: m['id'].toString(), moduleTitle: m['title']?.toString())),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => _confirmDelete('Delete this module and its lessons?', () =>
                  widget.auth.apiDelete('/api/v1/manage/modules/${m['id']}')),
              child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red),
            ),
          ]),
          if (lessons.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...lessons.map((l) {
              final ll = l as Map<String, dynamic>;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Icon(_iconFor(ll['type']?.toString() ?? 'text'), size: 17, color: Palette.of(context).secondary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(ll['title']?.toString() ?? '', style: AppleTheme.body(context).copyWith(fontSize: 15))),
                  GestureDetector(
                    onTap: () => _confirmDelete('Delete this lesson?', () =>
                        widget.auth.apiDelete('/api/v1/manage/lessons/${ll['id']}')),
                    child: Icon(CupertinoIcons.minus_circle, size: 17, color: AppleColors.red.withOpacity(0.8)),
                  ),
                ]),
              );
            }),
          ],
          // Quizzes & assignments scoped to this module.
          ..._moduleAssessments(m['id'].toString()),
        ]),
      ),
    );
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
            if (isQuiz) _smallButton('Build', CupertinoIcons.slider_horizontal_3, () => _openQuizBuilder(m['id'].toString(), m['title']?.toString() ?? 'Quiz')),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => _confirmDelete('Delete this ${isQuiz ? 'quiz' : 'assignment'}?', () => widget.auth.apiDelete('/api/v1/manage/assessments/${m['id']}')),
              child: Icon(CupertinoIcons.minus_circle, size: 16, color: AppleColors.red.withOpacity(0.8)),
            ),
          ]),
        );
      }),
    ];
  }

  Future<void> _confirmDelete(String message, Future<dynamic> Function() action) async {
    final yes = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete'),
        content: Text(message),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
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
        decoration: BoxDecoration(color: p.accent.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: p.accent),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: p.accent, fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Future<void> _addModule() async {
    final title = TextEditingController();
    final ok = await showFormSheet(context, title: 'Add Module',
        builder: (_) => [sheetField(title, 'Module title', CupertinoIcons.folder)],
        onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      await widget.auth.apiPost('/api/v1/manage/courses/${widget.courseId}/modules', {'title': title.text.trim()});
      return null;
    });
    if (ok == true) _load();
  }

  Future<void> _addLesson(String moduleId) async {
    final title = TextEditingController();
    final body = TextEditingController();
    int type = 0; // text, video, link
    int vsrc = 0; // 0 = R2 (MP4), 1 = HLS (.m3u8)
    bool downloadable = true; // documents: may learners download it?
    final ok = await showFormSheet(context, title: 'Add Lesson', builder: (setS) => [
      sheetField(title, 'Lesson title', CupertinoIcons.doc_text),
      const SizedBox(height: 10),
      AppleSegmented(labels: const ['Text', 'Video', 'Link', 'Document'], selected: type, onChanged: (i) => setS(() => type = i)),
      if (type == 1) ...[
        const SizedBox(height: 12),
        _label(context, 'Video source'),
        const SizedBox(height: 6),
        AppleSegmented(labels: const ['R2 (MP4)', 'HLS (.m3u8)'], selected: vsrc, onChanged: (i) => setS(() => vsrc = i)),
      ],
      const SizedBox(height: 10),
      sheetField(
        body,
        type == 0
            ? 'Content'
            : type == 1
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
      });
      return null;
    });
    if (ok == true) _load();
  }

  Future<void> _enroll() async {
    final email = TextEditingController();
    final ok = await showFormSheet(context, title: 'Enroll Student',
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
    final yes = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Reset all devices?'),
        content: Text('${widget.name} will be signed out on all devices and can bind fresh ones.'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (yes != true) return;
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
        decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(20)),
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
                  decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.circular(12)),
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
        decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(14)),
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

