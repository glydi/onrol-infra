import 'package:flutter/foundation.dart';

/// When built with --dart-define=STUDENT_APP=true (the Windows student app),
/// the app is a dedicated, light student LMS: it always lands on the student
/// home and never shows the staff console or the per-portal subdomain screens.
const bool kStudentApp = bool.fromEnvironment('STUDENT_APP');

/// The installable mobile app (Android / iOS) is a **user-only** app: it must
/// never surface the staff console or any per-portal screen, whatever the
/// account's role — even a staff member who signs in lands on the normal user
/// home. Admins manage the LMS from the web admin instead. Web and desktop
/// builds stay role-based.
bool get kUserOnlyApp =>
    kStudentApp ||
    (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS));
