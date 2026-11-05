# LaoLingo iOS
Native SwiftUI iOS app. iOS 17+; Liquid Glass on iOS 26+.
Backend: https://fy.atku.cn. Existing backend user credentials are required (not Apple login).
Features: daily translation, photo translation, AAC microphone input with manual stop/cancel and 1.5-second silence stop after speech, local records, swipe delete/mastery, sentence study, cached playback, appearance controls.
Source API compatibility is based on the supplied Android 1.3.0 backend. Newer backend changes need device validation.
Actions builds an unsigned IPA on macOS. It must be signed with a matching device provisioning profile before installation. The bundle identifier matches the supplied profile: app.tomato8957.cassava3272.
Never commit P12 files, passwords, provisioning profiles, backend provider keys, or user recordings.
Build status and device behavior must be checked before calling this release installable. No device test has been performed.
Audio silence threshold is -38 dBFS and may need tuning for noisy environments. Audio is cached after playback; study text is cached after generation. Initial study generation does not prefetch all word audio.

