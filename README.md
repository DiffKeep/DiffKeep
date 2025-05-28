# DiffKeep

_AI Generated Art Manager_

Manage your AI-generated images with ease. Sort, filter, search, delete, and organize.

## Feature Roadmap

- [x] Display images by folder or date
- [ ] View raw and parsed generation metadata
- [ ] Vector search image prompts. Prompt detection support for:
    - [ ] Comfyui
    - [ ] Automatic1111
    - [ ] Fooocus
    - [ ] CivitAI
    - _More to come_
- [ ] AI-generated image descriptions (also exposed in vector search)
- [ ] File drag and drop out support (DnD source), cross-platform
    - [x] Windows ("completed" but unverified)
    - [ ] Mac
    - [ ] Linux
        - [ ] X11
        - [ ] Wayland
- [ ] Integration with image generation tools:
    - [ ] ComfyUI
    - [ ] Internal image generation
- [ ] LiveGrid - Generate grids live in any dimension, save generated images with grid data, export any 2 dimensions to an image
- [ ] Use of "Processes" to generate and modify images in steps without leaving DiffKeep
- [ ] Project view to see all images related to a named project
- [ ] Integration with CivitAI if possible (see [CivitAI](https://github.com/civitai/civitai))
    - Currently (according to their wiki), this integration may be very limited in scope. Eventually I would like to enable posting images directly from DiffKeep.

## Development Notes

Have to have LibVips installed for your platform
https://github.com/kleisauke/net-vips#install