/*
 * dnd_win32.c — Windows OLE drag-and-drop source (no ATL/MFC).
 *
 * Exposes:
 *   BOOL dnd_win32_init(void)
 *   void dnd_win32_deinit(void)
 *   BOOL dnd_win32_start_drag(const wchar_t **paths, int path_count,
 *                              const void *ghost_rgba, int ghost_w, int ghost_h)
 *   BOOL dnd_win32_is_dragging(void)
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <ole2.h>
#include <shlobj.h>
#include <shellapi.h>
#include <stdatomic.h>
#include <string.h>
#include <stdlib.h>

/* ── IDropSource ──────────────────────────────────────────────────────────── */

typedef struct {
    IDropSourceVtbl *lpVtbl;
    LONG ref;
} MyDropSource;

static HRESULT STDMETHODCALLTYPE DS_QueryInterface(IDropSource *This,
    REFIID riid, void **ppv)
{
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IDropSource)) {
        *ppv = This;
        This->lpVtbl->AddRef(This);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE DS_AddRef(IDropSource *This) {
    return InterlockedIncrement(&((MyDropSource *)This)->ref);
}
static ULONG STDMETHODCALLTYPE DS_Release(IDropSource *This) {
    LONG n = InterlockedDecrement(&((MyDropSource *)This)->ref);
    if (n == 0) free(This);
    return (ULONG)n;
}
static HRESULT STDMETHODCALLTYPE DS_QueryContinueDrag(IDropSource *This,
    BOOL fEscapePressed, DWORD grfKeyState)
{
    (void)This;
    if (fEscapePressed) return DRAGDROP_S_CANCEL;
    if (!(grfKeyState & MK_LBUTTON)) return DRAGDROP_S_DROP;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE DS_GiveFeedback(IDropSource *This,
    DWORD dwEffect)
{
    (void)This; (void)dwEffect;
    return DRAGDROP_S_USEDEFAULTCURSORS;
}

static IDropSourceVtbl g_ds_vtbl = {
    DS_QueryInterface,
    DS_AddRef,
    DS_Release,
    DS_QueryContinueDrag,
    DS_GiveFeedback,
};

static MyDropSource *create_drop_source(void) {
    MyDropSource *p = (MyDropSource *)malloc(sizeof(*p));
    if (!p) return NULL;
    p->lpVtbl = &g_ds_vtbl;
    p->ref    = 1;
    return p;
}

/* ── IDataObject ──────────────────────────────────────────────────────────── */

/* Formats other code stores on the data object with SetData: the drag-image
   helper keeps the ghost image here ("DragImageBits", "DragContext", ...),
   and drop targets read it back through GetData / EnumFormatEtc. */
#define MAX_STORED 16
typedef struct {
    FORMATETC fe;
    STGMEDIUM medium; /* owned */
} StoredFormat;

typedef struct {
    IDataObjectVtbl *lpVtbl;
    LONG   ref;
    HGLOBAL hHDrop; /* CF_HDROP data */
    StoredFormat stored[MAX_STORED];
    int n_stored;
} MyDataObject;

static FORMATETC hdrop_format(void) {
    FORMATETC fe = { CF_HDROP, NULL, DVASPECT_CONTENT, -1, TYMED_HGLOBAL };
    return fe;
}

static StoredFormat *find_stored(MyDataObject *self, const FORMATETC *f) {
    for (int i = 0; i < self->n_stored; i++) {
        StoredFormat *s = &self->stored[i];
        if (s->fe.cfFormat == f->cfFormat && s->fe.dwAspect == f->dwAspect &&
            s->fe.lindex == f->lindex)
            return s;
    }
    return NULL;
}

/* A private copy of an HGLOBAL (for SetData without ownership). */
static HGLOBAL dup_hglobal(HGLOBAL src) {
    SIZE_T sz = GlobalSize(src);
    HGLOBAL dup = GlobalAlloc(GMEM_MOVEABLE, sz);
    if (!dup) return NULL;
    void *s = GlobalLock(src);
    void *d = GlobalLock(dup);
    if (s && d) memcpy(d, s, sz);
    if (d) GlobalUnlock(dup);
    if (s) GlobalUnlock(src);
    return dup;
}

static HRESULT STDMETHODCALLTYPE DO_QueryInterface(IDataObject *This,
    REFIID riid, void **ppv)
{
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IDataObject)) {
        *ppv = This;
        This->lpVtbl->AddRef(This);
        return S_OK;
    }
    *ppv = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE DO_AddRef(IDataObject *This) {
    return InterlockedIncrement(&((MyDataObject *)This)->ref);
}
static ULONG STDMETHODCALLTYPE DO_Release(IDataObject *This) {
    LONG n = InterlockedDecrement(&((MyDataObject *)This)->ref);
    if (n == 0) {
        MyDataObject *self = (MyDataObject *)This;
        if (self->hHDrop) GlobalFree(self->hHDrop);
        for (int i = 0; i < self->n_stored; i++) ReleaseStgMedium(&self->stored[i].medium);
        free(self);
    }
    return (ULONG)n;
}

static HRESULT STDMETHODCALLTYPE DO_GetData(IDataObject *This,
    FORMATETC *pFormatetc, STGMEDIUM *pMedium)
{
    MyDataObject *self = (MyDataObject *)This;
    if (pFormatetc->cfFormat != CF_HDROP) {
        /* A stored format: hand out the same medium, kept alive by a
           reference to this object (ReleaseStgMedium then releases that
           reference instead of freeing our copy). */
        StoredFormat *s = find_stored(self, pFormatetc);
        if (!s) return DV_E_FORMATETC;
        if (!(pFormatetc->tymed & s->medium.tymed)) return DV_E_TYMED;
        *pMedium = s->medium;
        pMedium->pUnkForRelease = (IUnknown *)This;
        This->lpVtbl->AddRef(This);
        return S_OK;
    }
    if (!(pFormatetc->tymed & TYMED_HGLOBAL)) return DV_E_TYMED;

    /* Duplicate our HGLOBAL so the caller can free it independently. */
    HGLOBAL dup = dup_hglobal(self->hHDrop);
    if (!dup) return E_OUTOFMEMORY;

    pMedium->tymed          = TYMED_HGLOBAL;
    pMedium->hGlobal        = dup;
    pMedium->pUnkForRelease = NULL;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE DO_GetDataHere(IDataObject *This,
    FORMATETC *f, STGMEDIUM *m) { (void)This;(void)f;(void)m; return E_NOTIMPL; }
static HRESULT STDMETHODCALLTYPE DO_QueryGetData(IDataObject *This,
    FORMATETC *pFormatetc)
{
    if (pFormatetc->cfFormat == CF_HDROP) return S_OK;
    return find_stored((MyDataObject *)This, pFormatetc) ? S_OK : DV_E_FORMATETC;
}
static HRESULT STDMETHODCALLTYPE DO_GetCanonicalFormatEtc(IDataObject *This,
    FORMATETC *in, FORMATETC *out)
{ (void)This;(void)in; out->ptd=NULL; return E_NOTIMPL; }
/* Store a format (the drag-image helper's ghost image, mostly). With
   fRelease the medium becomes ours; without it we keep a copy, which only
   HGLOBAL media support. */
static HRESULT STDMETHODCALLTYPE DO_SetData(IDataObject *This,
    FORMATETC *f, STGMEDIUM *m, BOOL fRelease)
{
    MyDataObject *self = (MyDataObject *)This;
    if (!f || !m) return E_INVALIDARG;
    if (f->cfFormat == CF_HDROP) return E_NOTIMPL; /* the files are fixed */

    STGMEDIUM owned = *m;
    if (!fRelease) {
        if (m->tymed != TYMED_HGLOBAL) return E_NOTIMPL;
        owned.hGlobal = dup_hglobal(m->hGlobal);
        if (!owned.hGlobal) return E_OUTOFMEMORY;
        owned.pUnkForRelease = NULL;
    }

    StoredFormat *s = find_stored(self, f);
    if (s) {
        ReleaseStgMedium(&s->medium);
    } else {
        if (self->n_stored == MAX_STORED) {
            if (!fRelease) ReleaseStgMedium(&owned);
            return E_OUTOFMEMORY;
        }
        s = &self->stored[self->n_stored++];
    }
    s->fe = *f;
    s->fe.ptd = NULL; /* device targets aren't kept */
    s->medium = owned;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE DO_EnumFormatEtc(IDataObject *This,
    DWORD dir, IEnumFORMATETC **pp)
{
    MyDataObject *self = (MyDataObject *)This;
    if (!pp) return E_INVALIDARG;
    *pp = NULL;
    if (dir != DATADIR_GET) return E_NOTIMPL;
    FORMATETC all[MAX_STORED + 1];
    all[0] = hdrop_format();
    for (int i = 0; i < self->n_stored; i++) all[i + 1] = self->stored[i].fe;
    return SHCreateStdEnumFmtEtc((UINT)(self->n_stored + 1), all, pp);
}
static HRESULT STDMETHODCALLTYPE DO_DAdvise(IDataObject *This,
    FORMATETC *f, DWORD a, IAdviseSink *s, DWORD *c)
{ (void)This;(void)f;(void)a;(void)s;(void)c; return OLE_E_ADVISENOTSUPPORTED; }
static HRESULT STDMETHODCALLTYPE DO_DUnadvise(IDataObject *This, DWORD c)
{ (void)This;(void)c; return OLE_E_ADVISENOTSUPPORTED; }
static HRESULT STDMETHODCALLTYPE DO_EnumDAdvise(IDataObject *This,
    IEnumSTATDATA **pp) { (void)This;(void)pp; return OLE_E_ADVISENOTSUPPORTED; }

static IDataObjectVtbl g_do_vtbl = {
    DO_QueryInterface,
    DO_AddRef,
    DO_Release,
    DO_GetData,
    DO_GetDataHere,
    DO_QueryGetData,
    DO_GetCanonicalFormatEtc,
    DO_SetData,
    DO_EnumFormatEtc,
    DO_DAdvise,
    DO_DUnadvise,
    DO_EnumDAdvise,
};

/* Build a CF_HDROP HGLOBAL from an array of wide-char paths. */
static HGLOBAL build_hdrop(const wchar_t **paths, int count) {
    /* Calculate total size: DROPFILES header + all paths + double-null. */
    size_t chars = 0;
    for (int i = 0; i < count; i++)
        chars += wcslen(paths[i]) + 1; /* include null terminator */
    chars += 1; /* double-null terminator */

    SIZE_T total = sizeof(DROPFILES) + chars * sizeof(wchar_t);
    HGLOBAL hg = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, total);
    if (!hg) return NULL;

    DROPFILES *df = (DROPFILES *)GlobalLock(hg);
    df->pFiles = sizeof(DROPFILES);
    df->fWide  = TRUE;

    wchar_t *dst = (wchar_t *)((char *)df + sizeof(DROPFILES));
    for (int i = 0; i < count; i++) {
        size_t len = wcslen(paths[i]) + 1;
        memcpy(dst, paths[i], len * sizeof(wchar_t));
        dst += len;
    }
    *dst = L'\0'; /* double-null */

    GlobalUnlock(hg);
    return hg;
}

static MyDataObject *create_data_object(const wchar_t **paths, int count) {
    MyDataObject *p = (MyDataObject *)malloc(sizeof(*p));
    if (!p) return NULL;
    p->lpVtbl = &g_do_vtbl;
    p->ref    = 1;
    p->n_stored = 0;
    p->hHDrop = build_hdrop(paths, count);
    if (!p->hHDrop) { free(p); return NULL; }
    return p;
}

/* ── Ghost image via IDragSourceHelper ────────────────────────────────────── */

static void try_set_ghost(IDataObject *data_obj,
    const void *rgba, int w, int h)
{
    if (!rgba || w <= 0 || h <= 0) return;

    /* Create a 32-bit top-down DIB (negative biHeight = top-down). */
    BITMAPINFO bi = {0};
    bi.bmiHeader.biSize        = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth       = w;
    bi.bmiHeader.biHeight      = -h; /* top-down */
    bi.bmiHeader.biPlanes      = 1;
    bi.bmiHeader.biBitCount    = 32;
    bi.bmiHeader.biCompression = BI_RGB;

    void *bits = NULL;
    HDC hdc = GetDC(NULL);
    HBITMAP hbm = CreateDIBSection(hdc, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    ReleaseDC(NULL, hdc);
    if (!hbm) return;

    /* RGBA → BGRA (Windows DIB order). */
    const unsigned char *src = (const unsigned char *)rgba;
    unsigned char       *dst = (unsigned char *)bits;
    for (int i = 0; i < w * h; i++) {
        dst[i*4 + 0] = src[i*4 + 2]; /* B */
        dst[i*4 + 1] = src[i*4 + 1]; /* G */
        dst[i*4 + 2] = src[i*4 + 0]; /* R */
        dst[i*4 + 3] = src[i*4 + 3]; /* A */
    }

    IDragSourceHelper *helper = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_DragDropHelper, NULL,
        CLSCTX_INPROC_SERVER, &IID_IDragSourceHelper, (void **)&helper);
    if (SUCCEEDED(hr) && helper) {
        SHDRAGIMAGE sdi = {0};
        sdi.sizeDragImage.cx = w;
        sdi.sizeDragImage.cy = h;
        sdi.ptOffset.x = w / 2;
        sdi.ptOffset.y = h / 2;
        sdi.hbmpDragImage = hbm;
        sdi.crColorKey    = CLR_NONE;
        /* On success the helper owns the bitmap (it stores it on the data
           object through SetData): only delete it on failure. */
        if (SUCCEEDED(helper->lpVtbl->InitializeFromBitmap(helper, &sdi, data_obj)))
            hbm = NULL;
        helper->lpVtbl->Release(helper);
    }
    if (hbm) DeleteObject(hbm);
}

/* ── Drag thread ──────────────────────────────────────────────────────────── */

/* Owned by the drag thread: deep copies of the caller's paths and ghost
   pixels, which the caller frees as soon as dnd_win32_start_drag returns. */
typedef struct {
    const wchar_t **paths;
    int             path_count;
    void           *ghost_rgba;
    int             ghost_w;
    int             ghost_h;
} DragArgs;

static void free_drag_args(DragArgs *args) {
    if (!args) return;
    if (args->paths) {
        for (int i = 0; i < args->path_count; i++) free((void *)args->paths[i]);
        free((void *)args->paths);
    }
    free(args->ghost_rgba);
    free(args);
}

static DragArgs *copy_drag_args(const wchar_t **paths, int path_count,
                                const void *ghost_rgba, int ghost_w, int ghost_h) {
    DragArgs *args = (DragArgs *)calloc(1, sizeof(*args));
    if (!args) return NULL;
    args->paths = (const wchar_t **)calloc((size_t)path_count, sizeof(wchar_t *));
    if (!args->paths) { free(args); return NULL; }
    for (int i = 0; i < path_count; i++) {
        size_t n = wcslen(paths[i]) + 1;
        wchar_t *copy = (wchar_t *)malloc(n * sizeof(wchar_t));
        if (!copy) { free_drag_args(args); return NULL; }
        memcpy(copy, paths[i], n * sizeof(wchar_t));
        args->paths[i] = copy;
        args->path_count = i + 1;
    }
    if (ghost_rgba && ghost_w > 0 && ghost_h > 0) {
        size_t bytes = (size_t)ghost_w * (size_t)ghost_h * 4;
        args->ghost_rgba = malloc(bytes);
        if (args->ghost_rgba) {
            memcpy(args->ghost_rgba, ghost_rgba, bytes);
            args->ghost_w = ghost_w;
            args->ghost_h = ghost_h;
        }
    }
    return args;
}

static volatile LONG g_dragging = 0; /* atomic bool */
static HANDLE        g_drag_thread = NULL;

static DWORD WINAPI drag_thread_proc(LPVOID param) {
    DragArgs *args = (DragArgs *)param;

    OleInitialize(NULL);

    MyDataObject *data_obj  = create_data_object(args->paths, args->path_count);
    MyDropSource *drop_src  = create_drop_source();
    if (data_obj && drop_src) {
        try_set_ghost((IDataObject *)data_obj,
            args->ghost_rgba, args->ghost_w, args->ghost_h);
        DWORD effect = 0;
        DoDragDrop((IDataObject *)data_obj, (IDropSource *)drop_src,
            DROPEFFECT_COPY, &effect);
    }
    if (data_obj) data_obj->lpVtbl->Release((IDataObject *)data_obj);
    if (drop_src) drop_src->lpVtbl->Release((IDropSource *)drop_src);

    free_drag_args(args);
    OleUninitialize();
    InterlockedExchange(&g_dragging, 0);
    return 0;
}

/* ── Public API ───────────────────────────────────────────────────────────── */

BOOL dnd_win32_init(void) {
    return SUCCEEDED(OleInitialize(NULL));
}

void dnd_win32_deinit(void) {
    if (g_drag_thread) {
        WaitForSingleObject(g_drag_thread, INFINITE);
        CloseHandle(g_drag_thread);
        g_drag_thread = NULL;
    }
    OleUninitialize();
}

BOOL dnd_win32_start_drag(
    const wchar_t **paths, int path_count,
    const void *ghost_rgba, int ghost_w, int ghost_h)
{
    if (InterlockedCompareExchange(&g_dragging, 1, 0) != 0) return FALSE;

    DragArgs *args = copy_drag_args(paths, path_count, ghost_rgba, ghost_w, ghost_h);
    if (!args) { InterlockedExchange(&g_dragging, 0); return FALSE; }

    if (g_drag_thread) { CloseHandle(g_drag_thread); g_drag_thread = NULL; }
    g_drag_thread = CreateThread(NULL, 0, drag_thread_proc, args, 0, NULL);
    if (!g_drag_thread) {
        free_drag_args(args);
        InterlockedExchange(&g_dragging, 0);
        return FALSE;
    }
    return TRUE;
}

BOOL dnd_win32_is_dragging(void) {
    return InterlockedCompareExchange(&g_dragging, 0, 0) != 0;
}
