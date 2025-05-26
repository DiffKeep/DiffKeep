using System;
using System.Threading.Tasks;

namespace DiffKeep.Extensions;

public static class TaskExtensions
{
    public static async void FireAndForget(this Task task)
    {
        try
        {
            await task;
        }
        catch (Exception ex)
        {
            // Log the error or handle it according to your error handling strategy
            Console.WriteLine($"Fire and forget task failed: {ex}");
        }
    }
}