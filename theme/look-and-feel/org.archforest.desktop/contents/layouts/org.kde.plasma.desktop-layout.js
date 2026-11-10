// arch-forest — раскладка рабочего стола:
//   * тонкая полупрозрачная панель сверху (меню, рабочие столы, часы, трей)
//   * плавающий док снизу (прячется, когда окно его закрывает)
//   * большие часы на рабочем столе и обои «Path» (тёмный лес)

var WALLPAPER = "/usr/share/wallpapers/Path/";

function existing(ids) {
    var out = [];
    for (var i = 0; i < ids.length; i++) {
        if (applicationExists(ids[i])) {
            out.push("applications:" + ids[i]);
        }
    }
    return out;
}

// ---------- Рабочие столы: обои + большие часы ----------
var desktopsArray = desktopsForActivity(currentActivity());
for (var j = 0; j < desktopsArray.length; j++) {
    var d = desktopsArray[j];
    d.wallpaperPlugin = "org.kde.image";
    d.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
    d.writeConfig("Image", "file://" + WALLPAPER);
    d.writeConfig("PreviewImage", "file://" + WALLPAPER);
}

if (desktopsArray.length > 0) {
    var desk = desktopsArray[0];
    var geo = screenGeometry(desk.screen);
    var cw = Math.round(Math.min(620, geo.width * 0.42));
    var ch = Math.round(cw * 0.42);
    var cx = Math.round((geo.width - cw) / 2);
    var cy = Math.round(geo.height * 0.09);
    var bigClock = desk.addWidget("org.kde.plasma.digitalclock", cx, cy, cw, ch);
    if (bigClock) {
        bigClock.userBackgroundHints = "NoBackground";
        bigClock.currentConfigGroup = ["Appearance"];
        bigClock.writeConfig("showDate", true);
        bigClock.writeConfig("dateDisplayFormat", 2);      // дата под временем
        bigClock.writeConfig("dateFormat", "longDate");
        bigClock.writeConfig("showSeconds", 0);
    }
}

// ---------- Верхняя тонкая панель ----------
var top = new Panel;
top.location = "top";
top.height = 2 * Math.ceil(gridUnit * 1.8 / 2);
top.floating = true;
top.opacity = "translucent";
top.hiding = "none";
top.lengthMode = "fill";

var kickoff = top.addWidget("org.kde.plasma.kickoff");
kickoff.currentConfigGroup = ["General"];
kickoff.writeConfig("icon", "archlinux-logo");

top.addWidget("org.kde.plasma.pager");
top.addWidget("org.kde.plasma.panelspacer");

var topClock = top.addWidget("org.kde.plasma.digitalclock");
topClock.currentConfigGroup = ["Appearance"];
topClock.writeConfig("showDate", true);
topClock.writeConfig("dateDisplayFormat", 1);              // дата рядом со временем
topClock.writeConfig("dateFormat", "custom");
topClock.writeConfig("customDateFormat", "ddd, d MMM");

top.addWidget("org.kde.plasma.panelspacer");
top.addWidget("org.kde.plasma.systemtray");

// ---------- Плавающий док снизу ----------
var dock = new Panel;
dock.location = "bottom";
dock.height = 2 * Math.ceil(gridUnit * 3 / 2);
dock.floating = true;
dock.opacity = "translucent";
dock.hiding = "dodgewindows";
dock.lengthMode = "fit";
dock.alignment = "center";

var tasks = dock.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers", existing([
    "org.kde.dolphin.desktop",
    "vivaldi-stable.desktop",
    "org.telegram.desktop.desktop",
    "discord.desktop",
    "steam.desktop",
    "org.kde.konsole.desktop",
    "obsidian.desktop",
    "systemsettings.desktop"
]));
tasks.writeConfig("showOnlyCurrentDesktop", false);
tasks.writeConfig("iconSpacing", 2);
tasks.writeConfig("groupingStrategy", 1);
