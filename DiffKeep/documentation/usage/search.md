## Search

Searching is one of the primary functions of DiffKeep. Finding an image that you generated six months ago can be
challenging if you have a large library. Being able to search your images can help to locate images quickly and easily.

There are currently two primary search modes, with more planned for the future. Each search mode has tradeoffs,
and understanding those tradeoffs is important to knowing which one you want to use.

### Full-Text Search (FTS)

Full-text search (or FTS) searches through the parsed prompts from your libraries. It is a little smarter than a simple
query match, and has a simple tokenizer, but it doesn't understand any meanings behind words.

For example, if you had an image with the prompt "golden carp swimming in a pond", a full-text search for "carp"
or "pond" would find this image, but a search for "fish" or "lake" would not.

The advantage of FTS is that it doesn't require any processing of images beyond the normal library scan,
so it's ready to go out of the box.

### Semantic search

Semantic search is a more intelligent search that can match image prompts based on ideas, rather than text.
This works by transforming each prompt into embeddings, which are a large set of floating-point numbers. The
numbers represent the meaning behind the words. When a search query is performed, the search itself is also
transformed into an embedding, and the program runs a distance function against the stored embeddings of the prompts
to find which ones most closely match the embeddings of the search query. 

From the example above of a prompt "golden carp swimming in a pond", semantic search allows you to search for "fish"
or "water" or "aquatic feature" and it will find that prompt, even though none of the words you searched for are
present in the prompt.

This powerful feature comes at a cost: transforming text into embeddings takes up-front processing power. With
semantic search enabled, each time a library scan is completed, DiffKeep will automatically scan that library for any
images with prompts that have not yet had embeddings created. Any found prompts will be added to a queue, and
embeddings will be generated and stored.

Embeddings are created by processing them through a specialized (or, more rarely, a general purpose) LLM, or
large language model. While the models typically used to generate embeddings are small and fast compared to a more
general purpose LLM, they still take a while to run.

If you have a video card available, DiffKeep will try to utilize it to greatly speed up the embedding generation.
If no video card is available, DiffKeep will fall back to CPU processing.