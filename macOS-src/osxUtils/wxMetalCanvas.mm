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
    PipelineInfo() {
        state = nil;
    }
    ~PipelineInfo() {
        state = nil;
    }
    id <MTLRenderPipelineState> state;
};


static id<MTLDevice> MTL_DEVICE = nil;
static id<MTLCommandQueue> MTL_COMMAND_QUEUE = nil;
static id<MTLLibrary> MTL_DEFAULT_LIBRARY = nil;
static std::map<std::string, PipelineInfo> PIPELINE_STATES;
static std::atomic_int METAL_USE_COUNT(0);



wxMetalCanvas::~wxMetalCanvas() {
    METAL_USE_COUNT--;

    if (METAL_USE_COUNT == 0) {
        for (auto &a : PIPELINE_STATES) {
            [a.second.state release];
            a.second.state = nil;
        }
        PIPELINE_STATES.clear();
        if (MTL_COMMAND_QUEUE) {
            MTL_COMMAND_QUEUE = nil;
        }
        if (MTL_DEFAULT_LIBRARY) {
            MTL_DEFAULT_LIBRARY = nil;
        }
        if (MTL_DEVICE) {
            MTL_DEVICE = nil;
        }
    }
}
MTKView* wxMetalCanvas::getMTKView() const {
    return (MTKView*)this->GetHandle();
}

id<MTLDevice> wxMetalCanvas::getMTLDevice() {
    return MTL_DEVICE;
}
id<MTLLibrary> wxMetalCanvas::getMTLLibrary() {
    return MTL_DEFAULT_LIBRARY;
}
id<MTLCommandQueue> wxMetalCanvas::getMTLCommandQueue() {
    return MTL_COMMAND_QUEUE;
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
        MTL_DEVICE = MTLCreateSystemDefaultDevice();
        MTL_COMMAND_QUEUE = [MTL_DEVICE newCommandQueue];
    }
    METAL_USE_COUNT++;



    NSRect r = wxOSXGetFrameForControl(this, pos , size);
    wxCustomMTKView* v = [[wxCustomMTKView alloc] initWithFrame:r device:MTL_DEVICE];
    [v retain];
    [v setPaused:true];
    [v setEnableSetNeedsDisplay:true];
    [v setColorPixelFormat:MTLPixelFormatBGRA8Unorm ];
    [v setClearColor:MTLClearColorMake(0, 0, 0, 1)];

    wxWidgetCocoaImpl* c = new wxWidgetCocoaImpl( this, v, wxWidgetImpl::Widget_UserKeyEvents | wxWidgetImpl::Widget_UserMouseEvents );
    SetPeer(c);
    MacPostControlCreate(pos, size) ;
    return true;
}


id<MTLRenderPipelineState> wxMetalCanvas::getPipelineState(const std::string &name, const char *vShader, const char *fShader, bool blending) {
    auto &a = PIPELINE_STATES[name];
    if (a.state == nil) {
        if (MTL_DEFAULT_LIBRARY == nil) {
            MTL_DEFAULT_LIBRARY = [MTL_DEVICE newDefaultLibrary];
        }
        @autoreleasepool {
            MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
            [desc colorAttachments][0].pixelFormat = [getMTKView() colorPixelFormat];
            if (blending) {
                [desc colorAttachments][0].blendingEnabled = true;
                [desc colorAttachments][0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                [desc colorAttachments][0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                [desc colorAttachments][0].sourceAlphaBlendFactor = MTLBlendFactorOne;
                [desc colorAttachments][0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            }

            NSString *nsVName= [[[NSString alloc] initWithUTF8String:vShader] autorelease];
            NSString *nsFName= [[[NSString alloc] initWithUTF8String:fShader] autorelease];

            desc.vertexFunction = [[MTL_DEFAULT_LIBRARY newFunctionWithName:nsVName] autorelease];
            desc.fragmentFunction = [[MTL_DEFAULT_LIBRARY newFunctionWithName:nsFName] autorelease];

            NSError *nserror;
            a.state = [[MTL_DEVICE newRenderPipelineStateWithDescriptor:desc error:&nserror] retain];
            [desc release];
            if (nserror) {
                [nserror release];
            }
        }
    }
    return a.state;
}
