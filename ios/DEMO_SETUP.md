# More & Protection demo

## Scope

Protection now has real, separately reported enforcement layers:

- **Inside ClearView:** existing adult-content, keyword, channel, Shorts, shared-blocklist and player checks remain intact.
- **Selected apps and websites:** Family Controls authorization, the system selection picker and a named Managed Settings store apply Screen Time shields. These settings follow the Protection switch. Expired phone-limit shields are independent and are removed by device authentication.
- **Safari:** the `ClearViewSafari` content-blocker extension receives the current website rules through the App Group. It blocks built-in adult domains, user-blocked domains and their subdomains. Disabling Protection publishes non-blocking rules. Keyword matching against page text, per-channel filtering and Shorts detection remain inside ClearView.
- **Family DNS:** installs a Cloudflare for Families DNS-over-HTTPS configuration. Configuration presence and actual iOS enabled status are reported separately. Enable it in iOS DNS Settings after installation. DNS is independent of the Protection switch, matching Android's separate DNS setup workflow.

Device settings are behind the Protection password gate and re-lock on background. Open Protection, set/unlock its password, then use **Device Protection** to configure the three layers. Permission denial, signing/configuration errors and rule-reload failures are displayed rather than treated as success.

## Required signing setup

Open `ClearView.xcodeproj` in Xcode and configure the **same development team** for:

1. `ClearView`
2. `ClearViewActivityMonitor`
3. `ClearViewSafari`

The project embeds both extensions and shares the appropriate Swift support folders with their targets.

Register and enable the App Group `group.com.muddassir.clearview` for all three targets. Enable **Family Controls** for the app and activity-monitor targets, **Network Extensions / DNS Settings** and **Time Sensitive Notifications** for the app. Regenerate provisioning profiles if Xcode cannot provision these entitlements automatically. Distribution builds may require additional Apple entitlement approval; a demo is not an entitlement bypass.

If you change the app bundle ID, also change both extension bundle IDs to use that prefix, and update the App Group identifiers in the entitlement files, `DeviceControlState.swift` and `SafariRulesFile.swift` to a group registered to your team. The Safari extension ID must end in `.safari`.

Use a real, correctly signed iPhone for Screen Time and system DNS review. These integrations have **not** been built or device-verified in this change. No tests, builds, lint or simulator checks were run, at the user's request; Xcode is also absent from the current development machine.

## Manual demo walkthrough

1. Unlock Protection and enable its main switch. Existing ClearView content filtering continues to work with its existing rules and models.
2. Open **Apps & Screen Time**, allow individual authorization, choose apps/categories/websites and save. Enable app blocking and/or the adult-web filter. The status card distinguishes permission from enabled restrictions.
3. Open **Safari websites**. Enable **ClearView Website Protection** under Settings → Apps → Safari → Extensions. Return to refresh status. Adding/removing websites or changing the main Protection switch reloads Safari rules automatically. Configure Safari profile/private-browsing permissions where available.
4. Open **DNS Protection**, install the configuration, then select it under Settings → General → VPN & Device Management → DNS. Return to see its actual enabled status. Removal requires a confirmation and removes only ClearView's matching configuration.
5. Background and return to any device-protection settings screen: it requires the Protection password again.
6. In More → Set Phone Limit, choose hours/minutes/seconds. Optionally select apps to restrict at expiry. After expiry, unlock the session using Face ID, Touch ID or the device passcode.

## Platform boundaries

- Stock iOS does not expose another app's screen text, allow ClearView to force-close Incognito/other apps, or provide a third-party whole-device lock. Those Android workflows cannot be made real merely by using a development build.
- Individual Screen Time authorization, Safari extension permissions and DNS configuration can be revoked by the device owner. This is not uninstall protection or device-owner administration.
- The activity-monitor extension schedules an interval starting at the phone-limit deadline; iOS determines background callback delivery. Exact second-level background enforcement is not guaranteed. ClearView refreshes the deadline locally each second while active and when returning to foreground.
- Screen Time custom-domain filtering is limited to the first 50 user domains. Safari and ClearView's own rules retain the full list. DNS uses the provider's domain categories, not the custom keyword/channel list.
- DNS does not inspect page contents or individual videos and can be superseded by other VPN/DNS settings. The selected provider receives DNS requests; in-app matching remains on-device. Shared-blocklist suggestions are sent only through the existing submission flow.

## Other More work already in progress

This change also completes the existing task editor's weekdays, time ranges, strict intervals, attempted/time-tracking actions and reminder configuration without discarding stored fields. Todo notifications are rebuilt from real tasks on changes/foreground, with a bounded upcoming queue that reserves space for other notifications. Open ClearView periodically to replenish that queue. Notification delivery still depends on iOS permissions, Focus and system settings; Android-style continuously ringing alarms are not implemented.

Dhikr management uses the existing codec/store for full phrase editing, custom targets, search, visibility, ordering, deletion and reset confirmations. These additions do not replace existing data or touch Media or Good Post.
