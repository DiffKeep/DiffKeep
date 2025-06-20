using System;
using System.Globalization;
using Avalonia.Data.Converters;
using DiffKeep.Repositories;
using DiffKeep.Services;

namespace DiffKeep.Converters;

public class EnumToDisplayNameConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is ImageSortOption sortOption)
        {
            return sortOption switch
            {
                ImageSortOption.NewestFirst => "Newest First",
                ImageSortOption.OldestFirst => "Oldest First",
                ImageSortOption.NameAscending => "Name A-Z",
                ImageSortOption.NameDescending => "Name Z-A",
                _ => sortOption.ToString()
            };
        }
        else if (value is SearchTypeEnum searchType)
        {
            return searchType switch
            {
                SearchTypeEnum.FullText => "Full Text",
                SearchTypeEnum.Semantic => "Semantic",
                SearchTypeEnum.Hybrid => "Hybrid",
                _ => searchType.ToString()
            };
        }
        return value?.ToString();
    }

    public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        throw new NotImplementedException();
    }
}