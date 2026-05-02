#include <windows.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <dcomp.h>

#include <cstdint>
#include <new>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dcomp.lib")

struct DxgiOverlayContext {
    ID3D11Device* d3d_device = nullptr;
    ID3D11DeviceContext* d3d_context = nullptr;
    IDXGISwapChain1* swapchain = nullptr;
    IDCompositionDevice* dcomp_device = nullptr;
    IDCompositionTarget* dcomp_target = nullptr;
    IDCompositionVisual* dcomp_visual = nullptr;
    UINT width = 0;
    UINT height = 0;
    std::vector<std::uint8_t> premul_bgra;
};

template <typename T>
static void safe_release(T*& ptr) {
    if (ptr) {
        ptr->Release();
        ptr = nullptr;
    }
}

static LONG resize_swapchain(DxgiOverlayContext* ctx, UINT width, UINT height) {
    if (!ctx || !ctx->swapchain) return E_POINTER;
    if (width == 0 || height == 0) return E_INVALIDARG;

    if (ctx->width == width && ctx->height == height) return S_OK;

    HRESULT hr = ctx->swapchain->ResizeBuffers(2, width, height, DXGI_FORMAT_B8G8R8A8_UNORM, 0);
    if (FAILED(hr)) return hr;

    ctx->width = width;
    ctx->height = height;
    ctx->premul_bgra.resize(static_cast<size_t>(width) * static_cast<size_t>(height) * 4u);

    if (ctx->dcomp_device) {
        hr = ctx->dcomp_device->Commit();
        if (FAILED(hr)) return hr;
    }

    return S_OK;
}

extern "C" __declspec(dllexport) void* dxgi_overlay_create(void* hwnd_void, int width, int height) {
    if (!hwnd_void || width <= 0 || height <= 0) return nullptr;

    auto* ctx = new (std::nothrow) DxgiOverlayContext();
    if (!ctx) return nullptr;

    const HWND hwnd = reinterpret_cast<HWND>(hwnd_void);

    UINT create_flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    const D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
    };

    D3D_FEATURE_LEVEL out_level = D3D_FEATURE_LEVEL_11_0;
    HRESULT hr = D3D11CreateDevice(
        nullptr,
        D3D_DRIVER_TYPE_HARDWARE,
        nullptr,
        create_flags,
        levels,
        ARRAYSIZE(levels),
        D3D11_SDK_VERSION,
        &ctx->d3d_device,
        &out_level,
        &ctx->d3d_context);

    if (FAILED(hr)) {
        delete ctx;
        return nullptr;
    }

    IDXGIDevice* dxgi_device = nullptr;
    IDXGIAdapter* dxgi_adapter = nullptr;
    IDXGIFactory2* dxgi_factory = nullptr;

    hr = ctx->d3d_device->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void**>(&dxgi_device));
    if (FAILED(hr)) {
        safe_release(ctx->d3d_context);
        safe_release(ctx->d3d_device);
        delete ctx;
        return nullptr;
    }

    hr = dxgi_device->GetAdapter(&dxgi_adapter);
    if (FAILED(hr)) {
        safe_release(dxgi_device);
        safe_release(ctx->d3d_context);
        safe_release(ctx->d3d_device);
        delete ctx;
        return nullptr;
    }

    hr = dxgi_adapter->GetParent(__uuidof(IDXGIFactory2), reinterpret_cast<void**>(&dxgi_factory));
    if (FAILED(hr)) {
        safe_release(dxgi_adapter);
        safe_release(dxgi_device);
        safe_release(ctx->d3d_context);
        safe_release(ctx->d3d_device);
        delete ctx;
        return nullptr;
    }

    DXGI_SWAP_CHAIN_DESC1 swap_desc = {};
    swap_desc.Width = static_cast<UINT>(width);
    swap_desc.Height = static_cast<UINT>(height);
    swap_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    swap_desc.Stereo = FALSE;
    swap_desc.SampleDesc.Count = 1;
    swap_desc.SampleDesc.Quality = 0;
    swap_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap_desc.BufferCount = 2;
    swap_desc.Scaling = DXGI_SCALING_STRETCH;
    swap_desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    swap_desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    swap_desc.Flags = 0;

    hr = dxgi_factory->CreateSwapChainForComposition(ctx->d3d_device, &swap_desc, nullptr, &ctx->swapchain);
    if (FAILED(hr)) {
        safe_release(dxgi_factory);
        safe_release(dxgi_adapter);
        safe_release(dxgi_device);
        safe_release(ctx->d3d_context);
        safe_release(ctx->d3d_device);
        delete ctx;
        return nullptr;
    }

    hr = DCompositionCreateDevice(dxgi_device, __uuidof(IDCompositionDevice), reinterpret_cast<void**>(&ctx->dcomp_device));
    if (FAILED(hr)) {
        safe_release(ctx->swapchain);
        safe_release(dxgi_factory);
        safe_release(dxgi_adapter);
        safe_release(dxgi_device);
        safe_release(ctx->d3d_context);
        safe_release(ctx->d3d_device);
        delete ctx;
        return nullptr;
    }

    hr = ctx->dcomp_device->CreateTargetForHwnd(hwnd, TRUE, &ctx->dcomp_target);
    if (FAILED(hr)) {
        safe_release(ctx->dcomp_device);
        safe_release(ctx->swapchain);
        safe_release(dxgi_factory);
        safe_release(dxgi_adapter);
        safe_release(dxgi_device);
        safe_release(ctx->d3d_context);
        safe_release(ctx->d3d_device);
        delete ctx;
        return nullptr;
    }

    hr = ctx->dcomp_device->CreateVisual(&ctx->dcomp_visual);
    if (FAILED(hr)) {
        safe_release(ctx->dcomp_target);
        safe_release(ctx->dcomp_device);
        safe_release(ctx->swapchain);
        safe_release(dxgi_factory);
        safe_release(dxgi_adapter);
        safe_release(dxgi_device);
        safe_release(ctx->d3d_context);
        safe_release(ctx->d3d_device);
        delete ctx;
        return nullptr;
    }

    hr = ctx->dcomp_visual->SetContent(ctx->swapchain);
    if (FAILED(hr)) {
        safe_release(ctx->dcomp_visual);
        safe_release(ctx->dcomp_target);
        safe_release(ctx->dcomp_device);
        safe_release(ctx->swapchain);
        safe_release(dxgi_factory);
        safe_release(dxgi_adapter);
        safe_release(dxgi_device);
        safe_release(ctx->d3d_context);
        safe_release(ctx->d3d_device);
        delete ctx;
        return nullptr;
    }

    hr = ctx->dcomp_target->SetRoot(ctx->dcomp_visual);
    if (FAILED(hr)) {
        safe_release(ctx->dcomp_visual);
        safe_release(ctx->dcomp_target);
        safe_release(ctx->dcomp_device);
        safe_release(ctx->swapchain);
        safe_release(dxgi_factory);
        safe_release(dxgi_adapter);
        safe_release(dxgi_device);
        safe_release(ctx->d3d_context);
        safe_release(ctx->d3d_device);
        delete ctx;
        return nullptr;
    }

    hr = ctx->dcomp_device->Commit();
    if (FAILED(hr)) {
        safe_release(ctx->dcomp_visual);
        safe_release(ctx->dcomp_target);
        safe_release(ctx->dcomp_device);
        safe_release(ctx->swapchain);
        safe_release(dxgi_factory);
        safe_release(dxgi_adapter);
        safe_release(dxgi_device);
        safe_release(ctx->d3d_context);
        safe_release(ctx->d3d_device);
        delete ctx;
        return nullptr;
    }

    ctx->width = static_cast<UINT>(width);
    ctx->height = static_cast<UINT>(height);
    ctx->premul_bgra.resize(static_cast<size_t>(width) * static_cast<size_t>(height) * 4u);

    safe_release(dxgi_factory);
    safe_release(dxgi_adapter);
    safe_release(dxgi_device);

    return ctx;
}

extern "C" __declspec(dllexport) LONG dxgi_overlay_resize(void* ctx_void, int width, int height) {
    if (!ctx_void) return E_POINTER;
    if (width <= 0 || height <= 0) return E_INVALIDARG;
    auto* ctx = reinterpret_cast<DxgiOverlayContext*>(ctx_void);
    return resize_swapchain(ctx, static_cast<UINT>(width), static_cast<UINT>(height));
}

extern "C" __declspec(dllexport) LONG dxgi_overlay_present_bgra_straight(
    void* ctx_void,
    const std::uint8_t* pixels,
    int width,
    int height,
    int stride_bytes) {
    if (!ctx_void || !pixels) return E_POINTER;
    if (width <= 0 || height <= 0 || stride_bytes < width * 4) return E_INVALIDARG;

    auto* ctx = reinterpret_cast<DxgiOverlayContext*>(ctx_void);

    LONG resize_hr = resize_swapchain(ctx, static_cast<UINT>(width), static_cast<UINT>(height));
    if (resize_hr < 0) return resize_hr;

    const size_t required = static_cast<size_t>(width) * static_cast<size_t>(height) * 4u;
    if (ctx->premul_bgra.size() != required) {
        ctx->premul_bgra.resize(required);
    }

    // Input is BGRA with straight alpha; convert to BGRA premultiplied alpha.
    for (int y = 0; y < height; ++y) {
        const std::uint8_t* src = pixels + static_cast<size_t>(y) * static_cast<size_t>(stride_bytes);
        std::uint8_t* dst = ctx->premul_bgra.data() + static_cast<size_t>(y) * static_cast<size_t>(width) * 4u;

        for (int x = 0; x < width; ++x) {
            const std::uint8_t b = src[0];
            const std::uint8_t g = src[1];
            const std::uint8_t r = src[2];
            const std::uint8_t a = src[3];

            dst[0] = static_cast<std::uint8_t>((static_cast<unsigned>(b) * static_cast<unsigned>(a) + 127u) / 255u);
            dst[1] = static_cast<std::uint8_t>((static_cast<unsigned>(g) * static_cast<unsigned>(a) + 127u) / 255u);
            dst[2] = static_cast<std::uint8_t>((static_cast<unsigned>(r) * static_cast<unsigned>(a) + 127u) / 255u);
            dst[3] = a;

            src += 4;
            dst += 4;
        }
    }

    ID3D11Texture2D* back_buffer = nullptr;
    HRESULT hr = ctx->swapchain->GetBuffer(0, __uuidof(ID3D11Texture2D), reinterpret_cast<void**>(&back_buffer));
    if (FAILED(hr)) return hr;

    D3D11_BOX region = {};
    region.left = 0;
    region.top = 0;
    region.front = 0;
    region.right = static_cast<UINT>(width);
    region.bottom = static_cast<UINT>(height);
    region.back = 1;

    ctx->d3d_context->UpdateSubresource(
        back_buffer,
        0,
        &region,
        ctx->premul_bgra.data(),
        static_cast<UINT>(width * 4),
        0);

    safe_release(back_buffer);

    hr = ctx->swapchain->Present(1, 0);
    if (FAILED(hr)) return hr;

    hr = ctx->dcomp_device->Commit();
    return hr;
}

extern "C" __declspec(dllexport) void dxgi_overlay_destroy(void* ctx_void) {
    if (!ctx_void) return;

    auto* ctx = reinterpret_cast<DxgiOverlayContext*>(ctx_void);

    safe_release(ctx->dcomp_visual);
    safe_release(ctx->dcomp_target);
    safe_release(ctx->dcomp_device);
    safe_release(ctx->swapchain);
    safe_release(ctx->d3d_context);
    safe_release(ctx->d3d_device);

    delete ctx;
}
