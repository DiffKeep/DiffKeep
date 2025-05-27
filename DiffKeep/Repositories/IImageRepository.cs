using System.Collections.Generic;
using System.Threading.Tasks;
using Avalonia.Media.Imaging;
using DiffKeep.Models;

namespace DiffKeep.Repositories;

public interface IImageRepository
{
    Task<IEnumerable<Image>> GetAllAsync();
    Task<Image?> GetByIdAsync(long id);
    Task<Image?> GetByPathAsync(long libraryId, string path);
    Task<Image?> GetByHashAsync(string hash);
    Task<IEnumerable<Image>> GetByLibraryIdAsync(long libraryId);
    Task<IEnumerable<Image>> GetByLibraryIdAndPathAsync(long libraryId, string path);
    Task<Dictionary<long, Bitmap?>> GetThumbnailsByIdsAsync(IEnumerable<long> ids);
    Task<long> AddAsync(Image image);
    Task AddBatchAsync(IEnumerable<Image> images);
    Task DeleteByLibraryIdAsync(long libraryId);
    Task UpdateAsync(Image image);
    Task UpdateThumbnailAsync(long imageId, Bitmap? thumbnail);
    Task DeleteAsync(long id);
    Task<bool> ExistsAsync(long libraryId, string path);
}