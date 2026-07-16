const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, ImageRun,
  AlignmentType, LevelFormat, BorderStyle, WidthType, ShadingType,
  HeadingLevel, PageBreak, PageOrientation
} = require("docx");

const ORANGE = "F5751F";
const DARK = "4E1E06";
const MUTED = "7A4A1F";

const head1 = (text) => new Paragraph({
  heading: HeadingLevel.HEADING_1,
  children: [new TextRun({ text, bold: true, size: 36, color: DARK, font: "Arial" })],
  spacing: { before: 360, after: 200 }
});

const head2 = (text) => new Paragraph({
  heading: HeadingLevel.HEADING_2,
  children: [new TextRun({ text, bold: true, size: 28, color: DARK, font: "Arial" })],
  spacing: { before: 280, after: 140 }
});

const para = (runs, opts = {}) => new Paragraph({
  children: Array.isArray(runs) ? runs : [new TextRun({ text: runs, size: 22, font: "Arial" })],
  spacing: { after: 140, line: 320 },
  ...opts
});

const bullet = (text) => new Paragraph({
  numbering: { reference: "bullets", level: 0 },
  children: [new TextRun({ text, size: 22, font: "Arial" })],
  spacing: { after: 80, line: 300 }
});

const numbered = (text) => new Paragraph({
  numbering: { reference: "steps", level: 0 },
  children: [new TextRun({ text, size: 22, font: "Arial" })],
  spacing: { after: 80, line: 300 }
});

const label = (text) => new TextRun({ text, bold: true, size: 22, font: "Arial", color: DARK });
const val = (text) => new TextRun({ text, size: 22, font: "Arial" });
const code = (text) => new TextRun({ text, size: 20, font: "Courier New" });

const border = { style: BorderStyle.SINGLE, size: 4, color: "E8DCC9" };
const borders = { top: border, bottom: border, left: border, right: border };

const tcell = (text, opts = {}) => new TableCell({
  borders,
  width: { size: opts.width || 4680, type: WidthType.DXA },
  shading: opts.shade ? { fill: opts.shade, type: ShadingType.CLEAR } : undefined,
  margins: { top: 100, bottom: 100, left: 140, right: 140 },
  children: [new Paragraph({
    children: [new TextRun({ text, size: 20, font: "Arial", bold: opts.bold || false, color: opts.bold ? DARK : "000000" })]
  })]
});

const screenshotsTable = new Table({
  width: { size: 9360, type: WidthType.DXA },
  columnWidths: [720, 3120, 5520],
  rows: [
    new TableRow({
      tableHeader: true,
      children: [
        tcell("#", { width: 720, shade: "FFF2E0", bold: true }),
        tcell("Screen", { width: 3120, shade: "FFF2E0", bold: true }),
        tcell("Headline / sub-headline", { width: 5520, shade: "FFF2E0", bold: true }),
      ]
    }),
    new TableRow({ children: [
      tcell("1", { width: 720, bold: true }),
      tcell("AI chat (hero)", { width: 3120 }),
      tcell("Log meals by chatting. — No more searching food databases. Just say what you ate.", { width: 5520 }),
    ]}),
    new TableRow({ children: [
      tcell("2", { width: 720, bold: true }),
      tcell("Daily log + macros", { width: 3120 }),
      tcell("Hit your macros. Every single day. — Calories, protein, carbs, and fat in one live snapshot.", { width: 5520 }),
    ]}),
    new TableRow({ children: [
      tcell("3", { width: 720, bold: true }),
      tcell("Nutrition details", { width: 3120 }),
      tcell("Every macro. Every micro. — Calories, protein, fiber, sodium — all against your goals.", { width: 5520 }),
    ]}),
    new TableRow({ children: [
      tcell("4", { width: 720, bold: true }),
      tcell("Weight trend (30D)", { width: 3120 }),
      tcell("See the trend. Not the noise. — Smoothed weekly averages cut through daily weight swings.", { width: 5520 }),
    ]}),
    new TableRow({ children: [
      tcell("5", { width: 720, bold: true }),
      tcell("Weight insights", { width: 3120 }),
      tcell("Know if you're actually losing. — Real-time velocity tells you when to push and when to hold.", { width: 5520 }),
    ]}),
    new TableRow({ children: [
      tcell("6", { width: 720, bold: true }),
      tcell("Integrations / settings", { width: 3120 }),
      tcell("Apple Health, Garmin, iCloud. — Your training auto-adjusts your calorie goal. Synced. Private.", { width: 5520 }),
    ]}),
  ]
});

const doc = new Document({
  creator: "Nomva",
  title: "Nomva — Custom Product Page Plan",
  styles: {
    default: { document: { run: { font: "Arial", size: 22 } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 36, bold: true, font: "Arial", color: DARK },
        paragraph: { spacing: { before: 360, after: 200 }, outlineLevel: 0 } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 28, bold: true, font: "Arial", color: DARK },
        paragraph: { spacing: { before: 280, after: 140 }, outlineLevel: 1 } },
    ]
  },
  numbering: {
    config: [
      { reference: "bullets",
        levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 540, hanging: 270 } } } }] },
      { reference: "steps",
        levels: [{ level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 540, hanging: 360 } } } }] },
    ]
  },
  sections: [{
    properties: {
      page: {
        size: { width: 12240, height: 15840 },
        margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 }
      }
    },
    children: [
      new Paragraph({
        children: [new TextRun({ text: "Nomva", bold: true, size: 56, color: ORANGE, font: "Arial" })],
        spacing: { after: 60 }
      }),
      new Paragraph({
        children: [new TextRun({ text: "Custom Product Page Plan", bold: true, size: 40, color: DARK, font: "Arial" })],
        spacing: { after: 80 }
      }),
      new Paragraph({
        children: [new TextRun({ text: "Variant: Macro & Fitness Trackers — May 2026", size: 22, color: MUTED, italics: true, font: "Arial" })],
        spacing: { after: 480 }
      }),

      head1("What this is"),
      para("A Custom Product Page (CPP) is a variant of your App Store listing with its own screenshots, app preview videos, and promotional text. Apple gives you up to 35 variants per app. Each one has a unique URL that you point ad campaigns and referral traffic to. Organic App Store search traffic still goes to your default listing — CPPs only show up when someone clicks a CPP-tagged link."),
      para("This plan covers the first variant: a page targeted at lifters, cutters, athletes, and other serious macro trackers. The goal is to convert paid and referral traffic from that audience at a meaningfully higher rate than the default page."),

      head1("Who this variant is for"),
      para("Macro and fitness trackers — people who log every meal because their training depends on it. They have specific calorie and macro targets, they care about precision, and they are often migrating from MyFitnessPal (too slow, too many ads) or spreadsheets (too tedious)."),
      para("What they care about, in order:"),
      bullet("Speed of logging — they log 4-6 times a day"),
      bullet("Macro targets, not just calories"),
      bullet("Trends in weight that ignore daily water fluctuations"),
      bullet("Integration with their training data (Apple Health, Garmin)"),
      bullet("Privacy and data ownership (iCloud over third-party cloud)"),

      head1("Screenshot order and copy"),
      para("The 6 PNGs are in your Projects/Nomva/AppStore-Marketing/output folder. Upload them in this order — App Store Connect renders them in upload order, and the first 3 are what shows up in search-result previews."),
      screenshotsTable,
      new Paragraph({ children: [new TextRun({ text: "" })], spacing: { after: 200 } }),

      head1("Promotional text"),
      para("The promotional text is the one piece of text you can change per CPP (up to 170 characters, no review required for edits)."),
      para("Recommended copy for this variant:"),
      para([
        new TextRun({ text: "The fastest macro tracker on iOS. Log meals by chatting. Smoothed weight trends. Apple Health and Garmin synced. Built for serious training.",
          italics: true, size: 22, font: "Arial", color: DARK })
      ]),
      para("Two backup variants for A/B testing later:"),
      bullet("Lifters, cutters, athletes — Nomva is the macro tracker that doesn't slow you down. Just say what you ate. Smoothed weight trends. Built for the work."),
      bullet("Macro tracking without the database hunting. Chat your meals in. Watch the trend. Sync with Apple Health and Garmin. Made for training."),

      head1("App name, subtitle, and description"),
      para("Apple does not let you change app name, subtitle, keywords, or description per CPP — those are global to your listing. If your current subtitle isn't already macro-leaning, consider editing it on your main listing to one of these (30 character max):"),
      bullet("Hit your macros, faster. (24)"),
      bullet("Macro tracking that's fast. (27)"),
      bullet("Just chat your meals. (21)"),

      new Paragraph({ children: [new PageBreak()] }),

      head1("Setup in App Store Connect"),
      numbered("Open App Store Connect and select Nomva."),
      numbered("In the left sidebar, click Distribution → Custom Product Pages."),
      numbered("Click the blue + button. Name it \"Macro & Fitness Trackers\" — this name is internal only."),
      numbered("Click into the variant. Select your default localization (English U.S.) and click Edit."),
      numbered("Upload the 6 screenshots from Projects/Nomva/AppStore-Marketing/output in order 01 through 06. The order at upload determines the order shoppers see."),
      numbered("Paste the promotional text from this doc into the Promotional Text field."),
      numbered("Skip App Preview Videos for v1. We can shoot one later — 30 seconds is plenty, screen-recorded chat logging set to upbeat audio works well."),
      numbered("Click Save."),
      numbered("Click Submit for Review. Apple reviews CPPs separately and usually approves within 24 hours."),
      numbered("Once approved, open the variant. The URL field at the top is your CPP link — copy it. That's the link you point traffic at."),

      head1("Where to send the traffic"),
      para("The CPP link only matters if you actually point campaigns at it. Three starting channels worth testing in the first 30 days:"),
      bullet("Apple Search Ads — create a campaign targeting keywords \"macro tracker\", \"calorie counter\", \"fitness tracker\", \"meal tracker\", and set the destination URL to your CPP. Start with $25/day budget per keyword group."),
      bullet("Reddit promoted posts in r/Fitness, r/leangains, r/loseit, r/xxfitness — short post, screenshot of the chat logging, link to the CPP."),
      bullet("Fitness creator partnerships — give a creator (lifter, coach, nutritionist) a unique CPP link. Pay flat per post or revenue-share. Their bio link becomes your CPP."),

      head1("How to know it's working"),
      para("App Store Connect → Analytics → Custom Product Pages shows per-variant impressions, downloads, and conversion rate. After ~500 impressions you'll have enough data to compare conversion vs. your default page. If the CPP isn't beating default by 20%+, swap the lead screenshot (try #2 macros or #4 weight trend as the hero) and re-test."),

      head1("Round 2 ideas"),
      bullet("Second variant for weight-loss audience — lead with the weight trend screenshot, headline like \"Steady weight loss. Without obsessing.\""),
      bullet("Third variant for privacy / iCloud crowd — lead with integrations screenshot, emphasize iCloud and on-device intelligence."),
      bullet("Add a 15-30 second app preview video showing the chat logging flow end-to-end. Apple weights preview videos heavily in the search result preview."),
      bullet("Once the macro/fitness variant is converting well, lift the winning headlines into the main listing's subtitle for organic traffic."),
    ]
  }]
});

Packer.toBuffer(doc).then(buf => {
  const outPath = "/sessions/keen-elegant-maxwell/mnt/Nomva/AppStore-Marketing/Nomva_CPP_Plan.docx";
  fs.writeFileSync(outPath, buf);
  console.log("wrote " + outPath);
});
