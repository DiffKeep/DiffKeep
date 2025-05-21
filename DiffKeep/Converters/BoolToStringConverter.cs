using System;
using System.Globalization;
using Avalonia;
using Avalonia.Data.Converters;

namespace DiffKeep.Converters;

public class BoolToStringConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is bool BoolValue && parameter is string p)
        {
            if (BoolValue)
            {
                return p;
            }
        }

        return AvaloniaProperty.UnsetValue;
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        throw new NotImplementedException();
    }

}