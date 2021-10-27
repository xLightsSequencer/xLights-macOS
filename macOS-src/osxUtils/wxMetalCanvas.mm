#include <map>

#include <TargetConditionals.h>
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>

#include "wxMetalCanvas.hpp"


#include "wx/frame.h"
#include "wx/log.h"
#include "wx/settings.h"
#include "wx/osx/private.h"


BEGIN_EVENT_TABLE(wxMetalCanvas, wxWindow)
END_EVENT_TABLE()


wxMetalCanvas::wxMetalCanvas(wxWindow *parent,
                             wxWindowID id,
                             const wxPoint& pos,
                             const wxSize& size,
                             long style,
                             const wxString& name)
{
    if (Create(parent, id, pos, size, wxFULL_REPAINT_ON_RESIZE | wxCLIP_CHILDREN | wxCLIP_SIBLINGS | style, name)) {

    }
}


@interface wxCustomMTKView : MTKView
{
}

@end

@implementation wxCustomMTKView

+ (void)initialize
{
    static BOOL initialized = NO;
    if (!initialized) {
        initialized = YES;
        wxOSXCocoaClassAddWXMethods( self );
    }
}

- (BOOL)isOpaque
{
    return YES;
}

- (BOOL) acceptsFirstResponder
{
    return YES;
}

// for special keys
- (void)doCommandBySelector:(SEL)aSelector
{
    wxWidgetCocoaImpl* impl = (wxWidgetCocoaImpl* ) wxWidgetImpl::FindFromWXWidget( self );
    if (impl)
        impl->doCommandBySelector(aSelector, self, _cmd);
}
@end


class PipelineInfo {
public:
    MTL::RenderPipelineDescriptor *pipeline = nullptr;
    MTL::RenderPipelineState state;
};

MTL::Device *wxMetalCanvas::device = nullptr;
MTL::CommandQueue *wxMetalCanvas::commandQueue = nullptr;
MTL::Library *wxMetalCanvas::library = nullptr;
static std::map<std::string, PipelineInfo> PIPELINE_STATES;
static std::atomic_int METAL_USE_COUNT(0);



wxMetalCanvas::~wxMetalCanvas() {
    METAL_USE_COUNT--;

    if (METAL_USE_COUNT == 0) {
        for (auto &a : PIPELINE_STATES) {
            delete a.second.pipeline;
        }
        PIPELINE_STATES.clear();
        if (commandQueue) {
            delete commandQueue;
        }
        if (library) {
            delete library;
        }
        if (device) {
            delete device;
        }
    }
}


bool wxMetalCanvas::Create(wxWindow *parent,
                           wxWindowID id,
                           const wxPoint& pos,
                           const wxSize& size,
                           long style,
                           const wxString& name) {
    DontCreatePeer();

    if (!wxWindow::Create(parent, id, pos, size, style, name)) {
        return false;
    }

    if (METAL_USE_COUNT == 0) {
        device = MTL::CreateSystemDefaultDevice();
        commandQueue = device->newCommandQueue();
    }
    METAL_USE_COUNT++;



    NSRect r = wxOSXGetFrameForControl(this, pos , size);
    wxCustomMTKView* v = [[wxCustomMTKView alloc] initWithFrame:r];

    [v setPaused:true];
    [v setEnableSetNeedsDisplay:true];
    [v setColorPixelFormat:MTLPixelFormatBGRA8Unorm ];
    [v setClearColor:MTLClearColorMake(0, 0, 0, 1)];

    wxWidgetCocoaImpl* c = new wxWidgetCocoaImpl( this, v, wxWidgetImpl::Widget_UserKeyEvents | wxWidgetImpl::Widget_UserMouseEvents );
    SetPeer(c);
    MacPostControlCreate(pos, size) ;

    view = new MTK::View(v, *device);

    return true;
}


MTL::RenderPipelineState wxMetalCanvas::getPipelineState(const std::string &name, const char *vShader, const char *fShader) {
    auto &a = PIPELINE_STATES[name];
    if (a.pipeline == nullptr) {
        if (library == nullptr) {
            library = device->newDefaultLibrary();
        }

        a.pipeline = new MTL::RenderPipelineDescriptor();
        a.pipeline->colorAttachments[0].pixelFormat(view->colorPixelFormat());

        a.pipeline->vertexFunction(library->newFunctionWithName(vShader));
        a.pipeline->fragmentFunction(library->newFunctionWithName(fShader));

        a.state = device->makeRenderPipelineState(*a.pipeline);
    }
    return a.state;
}
