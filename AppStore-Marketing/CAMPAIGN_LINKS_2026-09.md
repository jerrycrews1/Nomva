# Nomva campaign links and baseline

Generated in App Store Connect → Nomva → Analytics → Acquisition → Campaigns on September 22, 2026. Apple's UI generated these exact URLs and stated that at least five individual Apple Accounts must install through a campaign before that campaign appears in reporting.

| Channel | Campaign token | Link | Placement |
| --- | --- | --- | --- |
| Website | `launch_site_sep26` | `https://apps.apple.com/app/apple-store/id6762495287?pt=123122604&ct=launch_site_sep26&mt=8` | Both live Download buttons on `nomva.nerdquad.com` |
| Dedicated Instagram | `launch_ig_sep26` | `https://apps.apple.com/app/apple-store/id6762495287?pt=123122604&ct=launch_ig_sep26&mt=8` | [@nomvaapp](https://www.instagram.com/nomvaapp/) displays the branded `https://nomva.nerdquad.com/ig` link, which redirects to this exact Apple campaign URL |

The `/ig` redirect is in `server/index.js`. On September 23, the live route returned HTTP 302 with the exact Apple URL in `Location`, the server health check remained healthy, the Instagram profile displayed `nomva.nerdquad.com/ig`, and tapping it in the iPhone app opened Nomva's App Store listing.

Do not treat a missing campaign row as zero installs. Do not reuse the Instagram token for creator outreach or another channel. Use the plain public App Store URL for untracked contexts until a separate link is generated. The private pre-campaign analytics baseline is kept outside this public GitHub repository.
