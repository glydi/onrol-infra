import 'dart:html' as html;

/// Web-only: open YouTube Studio (80% of the screen, left) and the standalone
/// answer panel (20%, right) as two positioned browser windows, side by side.
/// Studio can't be iframe-embedded, so two real windows is the way to get the
/// "80/20 on one screen" layout the host wants.
void openStudioAndAnswers(String studioUrl, String answersUrl) {
  final screen = html.window.screen;
  final w = (screen?.width ?? html.window.innerWidth ?? 1440);
  final h = (screen?.height ?? html.window.innerHeight ?? 900);
  final studioW = (w * 0.7).floor();
  final answersW = w - studioW;

  String feats(int width, int left) =>
      'popup=yes,width=$width,height=$h,left=$left,top=0,noopener=no';

  // Studio on the left (80%). Answers on the right (20%). Opened in the same
  // click gesture so the popup blocker allows both.
  html.window.open(studioUrl, 'ytstudio', feats(studioW, 0));
  html.window.open(answersUrl, 'onrol_answers', feats(answersW, studioW));
}
