using System.Collections.Generic;
using Avalonia.Controls;
using Avalonia.Data.Converters;
using ShadUI.Themes;

namespace ShadUI.Demo.Converters;

public static class ThemeModeConverters
{
    private static readonly Dictionary<ThemeMode, string> Icons = new()
    {
        { ThemeMode.System, "SunMoon" },
        { ThemeMode.Light, "Sun" },
        { ThemeMode.Dark, "Moon" }
    };

    public static readonly IValueConverter ToLucideIcon =
        new FuncValueConverter<ThemeMode, string>(mode => Icons.TryGetValue(mode, out var icon) ? icon : Icons[0]);
}