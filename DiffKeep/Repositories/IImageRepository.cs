using System.Collections.Generic;
using System.Threading.Tasks;
using Avalonia.Media.Imaging;
using DiffKeep.Models;

namespace DiffKeep.Repositories;

public interface IImageRepository
{
    Task<IEnumerable<Image>> SearchByPromptAsync(string searchText, long? libraryId = null, string? directoryPath = null);

    Task<IEnumerable<Image>> GetAllAsync(ImageSortOption sortOption = ImageSortOption.NewestFirst);
    Task<Image?> GetByIdAsync(long id);
    Task<Image?> GetByPathAsync(long libraryId, string path, ImageSortOption sortOption = ImageSortOption.NewestFirst);
    Task<Image?> GetByHashAsync(string hash);

    Task<IEnumerable<Image>> GetByLibraryIdAsync(long libraryId,
        ImageSortOption sortOption = ImageSortOption.NewestFirst);

    Task<IEnumerable<Image>> GetByLibraryIdAndPathAsync(long libraryId, string path,
        ImageSortOption sortOption = ImageSortOption.NewestFirst);

    Task<int> GetCountAsync(long? libraryId = null, string? path = null);

    Task<int> GetSearchCountAsync(string searchText, long? libraryId = null,
        string? directoryPath = null);

    Task<IEnumerable<Image>> GetPagedAllAsync(int offset, int? limit, ImageSortOption sortOption);

    Task<IEnumerable<Image>> GetPagedByLibraryIdAsync(long libraryId, int offset, int? limit,
        ImageSortOption sortOption);

    Task<IEnumerable<Image>> GetPagedByLibraryIdAndPathAsync(long libraryId, string path, int offset, int? limit,
        ImageSortOption sortOption);

    Task<Dictionary<long, Bitmap?>> GetThumbnailsByIdsAsync(IEnumerable<long> ids);
    Task AddAsync(Image image);
    Task AddBatchAsync(IEnumerable<Image> images);
    Task DeleteByLibraryIdAsync(long libraryId);
    Task UpdateAsync(Image image);
    Task UpdateThumbnailAsync(long imageId, Bitmap? thumbnail);
    Task DeleteAsync(long id);
    Task DeleteAsync(long[] ids);
    Task<bool> ExistsAsync(long libraryId, string path);
    Task<IEnumerable<Image>> GetImagesWithoutEmbeddingsAsync(long? libraryId = null);
}

public enum ImageSortOption
{
    NewestFirst,
    OldestFirst,
    NameAscending,
    NameDescending
}