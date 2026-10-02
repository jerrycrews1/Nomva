# Privacy Policy for Nomva

Last updated: September 27, 2026

## Overview
Nomva helps you track meals, hydration, activity-based calorie targets, and weight. This policy describes current Nomva data handling. We do not sell personal information or use health data for advertising.

## Information stored on your device
Food logs, water entries, goals, weight history, custom foods, chat history, and related logging records are stored in the app's local storage. The iPhone app uses iOS data protection, and the Android app uses its app-private storage; neither is a separate password-protected vault. Nomva does not currently mirror this application history through CloudKit or maintain a server copy for history recovery.

## Apple Health, Health Connect, and Garmin
On iPhone, with your permission, Nomva reads active energy and body weight from Apple Health. Activity totals are refreshed on the device to update the selected activity source's calorie target. If you enable Save Nomva Weigh-ins, Nomva writes your Nomva-authored weights and their corrections to Apple Health. Removing one of those weights can also remove Nomva's corresponding Health sample after the undo period. Removing an imported weight in Nomva hides it locally without deleting another app's Health sample.

On Android, with your permission and the matching in-app sync controls enabled, Nomva reads up to 30 days of body weight and active calories from Health Connect. It can write weigh-ins you add in Nomva to Health Connect and delete its corresponding Health Connect records when you delete them in Nomva. Deleting an imported weight from Nomva does not delete another app's Health Connect record. Nomva stores local record identifiers and sync settings to limit duplicate imports and manage its own exports. You can manage Health Connect permissions in Android settings and turn off import, export, or activity reading in Nomva.

On iPhone, Garmin weight synchronization uses Garmin Connect → Apple Health → Nomva. Nomva can save its own weigh-ins to Apple Health; it does not write them to Garmin. Apple's Health synchronization is controlled separately by your Apple Account and Health settings. Nomva retains local sample identifiers, sync progress, and deletion preferences to avoid repeated imports.

A separate optional Garmin activity connection uses Nomva's server to receive daily activity summaries, including active calories and available steps/total calories. The server stores those summaries and the encrypted credentials needed to maintain the connection. Disconnecting Garmin in Nomva removes that connection and its cached activity summaries. The former direct Garmin weight import is retired; legacy body-composition deliveries are discarded.

Automatically imported Apple Health or Health Connect measurements and local weight notes are not attached to cloud AI requests. Supported weight-history questions are answered locally. Information you explicitly include in an AI message or chosen photo may be processed as described below. On iPhone, you can change Health permissions in the Health app and stop import/export in Nomva's Weight Sync settings.

## AI processing and food lookup
When you use cloud AI, your request text, limited relevant conversation or food context, and photos you choose to analyze are sent through Nomva's service to OpenAI for processing. Food and restaurant lookup may use online sources. Do not include information you do not want processed by these services. Provider processing is subject to that provider's policies.

Nomva does not intentionally retain full AI conversations or photos on its server after processing, and production diagnostics exclude raw request and response content. The service caches food names, lookup aliases, nutrition estimates, and published nutrition sources to improve future lookups; this cache is separate from your personal diary. Published lookup records normally expire after 180 days and estimates after 30 days.

The bundled food catalog combines USDA FoodData Central and Open Food Facts records, including Open Food Facts fields merged into some USDA rows. The complete combined catalog is available under the Open Database License; see [food data sources and license](https://nomva.nerdquad.com/data-sources.html) for attribution and a machine-readable download. Barcode lookup first checks that catalog and device cache. If needed, the barcode is sent directly to Open Food Facts without your chat or weight history. Manual logging is available without cloud AI.

## Diagnostics, access, and purchases
Nomva uses limited operational diagnostics such as hashed app identifiers, request route, response status, duration, model, and token counts. These records exclude raw chat text, photos, food names, barcodes, and weight values and are retained for up to 90 days. On iPhone, remove linked diagnostics in Settings → AI & Privacy → Delete Cloud Analytics. On Android, contact support to request deletion of linked service diagnostics.

The service retains authentication, subscription-verification, and request-limit records needed to provide and protect access. Apple handles iPhone subscription payments; Google Play handles Android subscription payments. Nomva receives verified entitlement information; it does not receive your payment-card details. Nomva does not include advertising frameworks or third-party analytics SDKs.

## Backups and recovery
Application history is excluded from automatic device backup. Export a JSON backup in Settings → Backup & Export before replacing your device or reinstalling Nomva. Exported backups and CSV reports contain personal information and are not password encrypted by Nomva; you choose where to save or share them. Their protection and retention depend on that destination. The Android and iPhone JSON backup formats are different and cannot be restored across platforms. The iPhone app keeps a protected local recovery copy before restoring an archive. That local copy cannot recover data after the app or device is lost. The Android app merges a selected backup into its local history without making a separate recovery copy.

Older Nomva versions may have placed copies in your private iCloud account. The current app preserves existing local history and does not automatically delete those older cloud copies; manage them in Apple Settings. Apple Health maintains its own history and synchronization separately.

## Deletion and your choices
You can delete entries in Nomva, stop Apple Health or Health Connect sharing, disconnect the Garmin activity connection, request deletion of linked cloud diagnostics, and export your data. Removing Nomva deletes its local app history and any local recovery copies; it does not automatically delete separately exported files, Apple Health or Health Connect records, older iCloud copies, or server-side Garmin credentials. Disconnect Garmin before removing the app, or contact support for assistance with remaining service records.

## Changes and contact
We update this page when our data practices change. For privacy requests, support, or questions about retained service records, contact [jerry@nerdquad.com](mailto:jerry@nerdquad.com).
