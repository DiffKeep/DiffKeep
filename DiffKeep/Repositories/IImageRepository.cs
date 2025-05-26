using System.Collections.Generic;
using System.Threading.Tasks;
using Avalonia.Media.Imaging;
using DiffKeep.Models;

namespace DiffKeep.Repositories;

public interface IImageRepository
{
    Task<Image?> GetByIdAsync(long id);
    Task<Image?> GetByPathAsync(long libraryId, string path);
    Task<Image?> GetByHashAsync(string hash);
    Task<IEnumerable<Image>> GetByLibraryIdAsync(long libraryId);
    Task<long> AddAsync(Image image);
    Task UpdateAsync(Image image);
    Task UpdateThumbnailAsync(long imageId, Bitmap? thumbnail);
    Task DeleteAsync(long id);
    Task<bool> ExistsAsync(long libraryId, string path);
}