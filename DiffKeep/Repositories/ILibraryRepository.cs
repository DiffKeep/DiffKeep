using System.Collections.Generic;
using System.Threading.Tasks;
using DiffKeep.Models;

namespace DiffKeep.Repositories;

public interface ILibraryRepository
{
    Task<Library?> GetByIdAsync(long id);
    Task<Library?> GetByPathAsync(string path);
    Task<IEnumerable<Library>> GetAllAsync();
    Task<long> AddAsync(Library library);
    Task UpdateAsync(Library library);
    Task DeleteAsync(long id);
    Task<bool> ExistsAsync(string path);
}