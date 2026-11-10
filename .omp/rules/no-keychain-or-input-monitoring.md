---
description: No Keychain items and no Input Monitoring
condition:
  - '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?\b(?:SecItem(?:Add|CopyMatching|Update|Delete)|kSecClass\w*|SecKeychain\w*)\b'
  - '(?m)^(?![ \t]*(?:/\*|\*))(?:(?!//)[^\n"]|"(?:[^"\\\n]|\\.)*")*?\b(?:IOHIDRequestAccess|IOHIDCheckAccess|kIOHIDRequestTypeListenEvent)\b'
  - 'keychain-access-groups'
scope:
  - 'tool:edit(**/Sources/**/*.swift)'
  - 'tool:write(**/Sources/**/*.swift)'
  - 'tool:edit(**/Resources/*.entitlements)'
  - 'tool:write(**/Resources/*.entitlements)'
---
No feature may depend on the Keychain: the one credential the app holds, the TypeSafe key, comes from the `TYPESAFE_API_KEY` environment variable or the owner-only `typesafe.key` file in the support directory (`TypeSafeKeySource`); the data-protection Keychain returns `errSecMissingEntitlement` (-34018), and ad-hoc `keychain-access-groups` fails AMFI. Never request Input Monitoring or its entitlement; hotkeys use the Accessibility-trusted event tap or passive monitors (docs/runtime.md).
