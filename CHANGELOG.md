## 5.1 (2026-06-13)

- Fixed table.remove and break on the same line in UpdateCompartmentButton — this was a Lua syntax issue that could prevent the compartment button from being unregistered correctly
- Fixed loginCheckDone being reset to false on every AuctionsCacheUpdate callback — this caused the expired auctions chat message to reprint every time the Auction House was opened rather than only once per login session
- Fixed double scrollbar appearing on the Config tab — UIPanelScrollFrameTemplate was adding its own built-in scrollbar alongside our MinimalScrollBar
- Fixed scrollbars showing when content fits in the visible area — added SetHideIfUnscrollable(true) to all three scrollbars (Summary/Details, Config panel, and popup)
- Popup alert now sorts the current logged-in character to the top of the list if they have expired auctions, followed by characters with the most expired auctions
- BuildAlerts now correctly excludes non-character keys (mainWindowPos, alertPopupPos, minimap) when iterating ExpiryTrackerDB to find characters with mailbox gold
- Removed top-level ExpiryTrackerDB = ExpiryTrackerDB or {} — WoW handles SavedVariables initialization automatically

## 5 (2026-06-04)
- Added Summary tab with per-character overview showing expired auctions, active auctions, mailbox gold, and next expiry time
- Added Config tab with alert thresholds, snooze duration, and UI toggles
- Added mailbox gold tracking per character
- Added login alert system with chat and popup alerts (snooze, dismiss, open summary)
- Added minimap button with saved position with custom icon
- Added addon compartment support
- Added totals row in Summary tab
- Added item tooltips and shift-click linking in Details tab
- Added persistent UI state for windows and popup
- Added `/etrdebug` command and Config debug button
- Updated toc file to support 12.0.5 and added Auctions category

## 4 (2026-01-24)

- Bump toc  
-  Better and dynamic representation of expiry times, relative times; some minor stuff #3  
