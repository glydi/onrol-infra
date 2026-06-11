import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import 'student_home.dart';

/// Student entry point — the ONROL checkerboard home.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.auth});
  final AuthService auth;

  @override
  Widget build(BuildContext context) => StudentHome(auth: auth);
}
