// Non-web platforms have no browser tab, so the unread-count badge is a no-op.
// The web implementation (tab_badge_web.dart) is swapped in via conditional
// import on dart.library.html.
void setUnreadBadge(int count) {}
