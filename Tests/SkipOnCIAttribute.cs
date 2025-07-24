namespace Tests;

/// <summary>
/// Attribute that extends FactAttribute to automatically skip tests when running in CI environment.
/// </summary>
public class SkipOnCIAttribute : FactAttribute
{
    public SkipOnCIAttribute()
    {
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CI")))
        {
            Skip = "Test skipped in CI environment";
        }
    }
}

/// <summary>
/// Attribute that extends TheoryAttribute to automatically skip tests when running in CI environment.
/// </summary>
public class SkipOnCITheoryAttribute : TheoryAttribute
{
    public SkipOnCITheoryAttribute()
    {
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CI")))
        {
            Skip = "Test skipped in CI environment";
        }
    }
}
