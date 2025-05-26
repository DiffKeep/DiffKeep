using System.Collections.Generic;
using System.Threading.Tasks;
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
    Task DeleteAsync(long id);
    Task<bool> ExistsAsync(long libraryId, string path);
}