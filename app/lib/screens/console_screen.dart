import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

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
          Expanded(child: PrimaryButton(label: 'Add Instructor', icon: CupertinoIcons.person_badge_plus, onPressed: () => _addPerson('instructor'))),
          const SizedBox(width: 12),
          Expanded(child: PrimaryButton(label: 'Add Student', icon: CupertinoIcons.person_add, onPressed: () => _addPerson('student'))),
        ]),
        const SizedBox(height: 22),
        if (others.isNotEmpty) ...[_peopleGroup('Admins', others), const SizedBox(height: 18)],
        _peopleGroup('Instructors (${instructors.length})', instructors),
        const SizedBox(height: 18),
        _peopleGroup('Students (${students.length})', students),
      ],
    );
  }

  Widget _peopleGroup(String title, List<dynamic> people) {
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
                onTap: () => _manageDevices(u['id'].toString(), u['full_name']?.toString() ?? 'User'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (u['is_active'] == false) const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Icon(CupertinoIcons.nosign, color: AppleColors.red, size: 18),
                  ),
                  Icon(CupertinoIcons.device_phone_portrait, color: Palette.of(context).accent, size: 20),
                ]),
              ),
            ]);
          })),
        ),
    ]);
  }

  // Device control: view a user's bound devices, revoke one, or reset all.
  Future<void> _manageDevices(String userId, String name) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DeviceSheet(auth: widget.auth, userId: userId, name: name),
    );
  }

  Future<void> _addPerson(String role) async {
    final email = TextEditingController();
    final name = TextEditingController();
    final pass = TextEditingController();
    final ok = await showFormSheet(context, title: role == 'instructor' ? 'Add Instructor' : 'Add Student', builder: (_) => [
      _sheetField(name, 'Full name', CupertinoIcons.person),
      const SizedBox(height: 10),
      _sheetField(email, 'Email', CupertinoIcons.mail),
      const SizedBox(height: 10),
      _sheetField(pass, 'Temporary password (min 8)', CupertinoIcons.lock),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty || email.text.trim().isEmpty) return 'Name and email required';
      if (pass.text.trim().length < 8) return 'Password must be at least 8 characters';
      try {
        await widget.auth.apiPost('/api/v1/manage/users', {
          'full_name': name.text.trim(),
          'email': email.text.trim(),
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
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: p.accent.withOpacity(0.35), offset: const Offset(0, 6), blurRadius: 14, spreadRadius: -3)],
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
          Column(mainAxisSize: MainAxisSize.min, children: [
            CupertinoSwitch(
              value: status == 'published',
              activeTrackColor: AppleColors.green,
              onChanged: (v) => _togglePublish(c['id'].toString(), v),
            ),
            Text(status == 'published' ? 'Visible' : 'Hidden',
                style: AppleTheme.footnote(context).copyWith(color: status == 'published' ? AppleColors.green : color)),
          ]),
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
    int enrollType = 0; // self, manual
    String instructorId = instructors.first['id'].toString();

    final created = await showFormSheet(
      context,
      title: 'New Course',
      builder: (setS) => [
        _sheetField(title, 'Course title', CupertinoIcons.textformat),
        const SizedBox(height: 10),
        _sheetField(desc, 'Description', CupertinoIcons.text_alignleft),
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
          await widget.auth.apiPost('/api/v1/manage/courses', {
            'title': title.text.trim(),
            'description': desc.text.trim(),
            'enroll_type': enrollType == 0 ? 'self' : 'manual',
            'instructor_id': instructorId,
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
                PrimaryButton(
                  label: 'Doubts & Discussion',
                  icon: CupertinoIcons.chat_bubble_2_fill,
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DiscussionScreen(auth: widget.auth, courseId: widget.courseId, title: widget.title))),
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
              Text(_fmtTime(s['starts_at']?.toString()), style: AppleTheme.footnote(context)),
            ]),
          ),
          Icon(hasLink ? CupertinoIcons.link : CupertinoIcons.exclamationmark_circle,
              size: 18, color: hasLink ? p.secondary : AppleColors.orange),
        ]),
      ),
    );
  }

  Future<void> _addSession() async {
    final title = TextEditingController();
    final url = TextEditingController();
    DateTime when = DateTime.now().add(const Duration(hours: 1));
    final ok = await showFormSheet(context, title: 'Add Live Class', builder: (setS) => [
      _sheetField(title, 'Title (e.g. Lecture 1)', CupertinoIcons.textformat),
      const SizedBox(height: 10),
      _sheetField(url, 'Live link (Zoho / Meet / Jitsi URL)', CupertinoIcons.link),
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
        ]),
      ),
    );
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
        _ => CupertinoIcons.doc_text,
      };

  Widget _smallButton(String label, IconData icon, VoidCallback onTap) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: p.accent.withOpacity(0.12), borderRadius: BorderRadius.circular(13)),
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
        builder: (_) => [_sheetField(title, 'Module title', CupertinoIcons.folder)],
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
    final ok = await showFormSheet(context, title: 'Add Lesson', builder: (setS) => [
      _sheetField(title, 'Lesson title', CupertinoIcons.doc_text),
      const SizedBox(height: 10),
      AppleSegmented(labels: const ['Text', 'Video', 'Link'], selected: type, onChanged: (i) => setS(() => type = i)),
      if (type == 1) ...[
        const SizedBox(height: 12),
        _label(context, 'Video source'),
        const SizedBox(height: 6),
        AppleSegmented(labels: const ['R2 (MP4)', 'HLS (.m3u8)'], selected: vsrc, onChanged: (i) => setS(() => vsrc = i)),
      ],
      const SizedBox(height: 10),
      _sheetField(
        body,
        type == 0
            ? 'Content'
            : type == 1
                ? (vsrc == 0 ? 'R2 video URL (…/video.mp4)' : 'HLS playlist URL (…/index.m3u8)')
                : 'URL',
        type == 1 ? (vsrc == 0 ? CupertinoIcons.play_rectangle : CupertinoIcons.antenna_radiowaves_left_right) : CupertinoIcons.link,
      ),
      if (type == 1) ...[
        const SizedBox(height: 6),
        _label(context, vsrc == 0
            ? 'Direct MP4 stored in Cloudflare R2. Streams; no download.'
            : 'HLS playlist (.m3u8) from R2/CDN. Adaptive streaming via hls.js.'),
      ],
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      if (type != 0 && body.text.trim().isEmpty) return type == 1 ? 'Video URL required' : 'URL required';
      await widget.auth.apiPost('/api/v1/manage/modules/$moduleId/lessons', {
        'title': title.text.trim(),
        'type': ['text', 'video', 'link'][type],
        'body': body.text.trim(),
      });
      return null;
    });
    if (ok == true) _load();
  }

  Future<void> _enroll() async {
    final email = TextEditingController();
    final ok = await showFormSheet(context, title: 'Enroll Student',
        builder: (_) => [_sheetField(email, 'Student email', CupertinoIcons.mail)],
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
  const _DeviceSheet({required this.auth, required this.userId, required this.name});
  final AuthService auth;
  final String userId;
  final String name;

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
          PrimaryButton(
            label: 'Reset all devices',
            icon: CupertinoIcons.arrow_counterclockwise,
            busy: _busy,
            onPressed: _devices.isEmpty ? null : _resetAll,
          ),
          const SizedBox(height: 6),
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Done', style: TextStyle(color: p.secondary))),
        ]),
      ),
    );
  }
}

// ---- shared sheet helpers --------------------------------------------------

Widget _sheetField(TextEditingController c, String hint, IconData icon) {
  return Builder(builder: (context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.circular(12)),
      child: AppleField(controller: c, hint: hint, icon: icon),
    );
  });
}

/// A reusable modal form sheet. onSubmit returns an error string or null on success.
Future<bool?> showFormSheet(
  BuildContext context, {
  required String title,
  required List<Widget> Function(void Function(void Function())) builder,
  required Future<String?> Function() onSubmit,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final p = Palette.of(ctx);
      bool busy = false;
      String? err;
      return StatefulBuilder(builder: (ctx, setS) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            margin: const EdgeInsets.all(10),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(16)),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(child: Text(title, style: AppleTheme.title2(ctx))),
              const SizedBox(height: 16),
              ...builder(setS),
              if (err != null) ...[
                const SizedBox(height: 12),
                Text(err!, style: AppleTheme.footnote(ctx).copyWith(color: AppleColors.red)),
              ],
              const SizedBox(height: 18),
              PrimaryButton(
                label: 'Save',
                busy: busy,
                onPressed: () async {
                  setS(() { busy = true; err = null; });
                  final e = await onSubmit();
                  if (e == null) {
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  } else {
                    setS(() { busy = false; err = e; });
                  }
                },
              ),
              const SizedBox(height: 6),
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: p.secondary))),
            ]),
          ),
        );
      });
    },
  );
}
