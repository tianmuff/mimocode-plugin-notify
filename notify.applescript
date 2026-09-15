-- Content arrives as arguments rather than executable AppleScript source.
-- Notification permissions, lifetime and click behavior are managed by macOS.
on run argv
  if (count of argv) is not 3 then error "Expected title, body and sound flag"
  set notificationTitle to item 1 of argv
  set notificationBody to item 2 of argv
  if item 3 of argv is "1" then
    display notification notificationBody with title notificationTitle sound name "Glass"
  else
    display notification notificationBody with title notificationTitle
  end if
end run
