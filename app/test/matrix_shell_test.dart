import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onrol_app/theme.dart';
import 'package:onrol_app/widgets/matrix_shell.dart';

// Pages shaped like the real student pages (RefreshIndicator > ListView), which
// is what actually gets rendered inside the shell.
Widget _listPage(String tag) => RefreshIndicator(
      onRefresh: () async {},
      child: ListView(children: [
        for (var i = 0; i < 20; i++) ListTile(title: Text('$tag $i')),
      ]),
    );

void main() {
  testWidgets('matrix renders, opens a page, and returns', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppleTheme.light(),
      home: MatrixShell(
        title: 'ONROL',
        subtitle: 'Hi, Test',
        items: [
          MatrixItem(icon: CupertinoIcons.house_fill, label: 'Home', color: AppleColors.blue, page: _listPage('Home')),
          MatrixItem(icon: CupertinoIcons.person_fill, label: 'Profile', color: AppleColors.purple, page: _listPage('Profile')),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    // Matrix landing shows the tiles.
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Hi, Test'), findsOneWidget);

    // Tap a tile -> its page appears.
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Home 0'), findsOneWidget);

    // Back chevron returns to the matrix.
    await tester.tap(find.byIcon(CupertinoIcons.chevron_back));
    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsOneWidget);
  });

  testWidgets('renders at a narrow phone size without overflow', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: AppleTheme.dark(),
      home: MatrixShell(
        title: 'ONROL',
        items: [
          MatrixItem(icon: CupertinoIcons.house_fill, label: 'Home', color: AppleColors.blue, page: _listPage('Home')),
          MatrixItem(icon: CupertinoIcons.person_fill, label: 'Profile', color: AppleColors.purple, page: _listPage('Profile')),
        ],
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
