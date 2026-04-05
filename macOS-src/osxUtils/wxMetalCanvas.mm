#include <TargetConditionals.h>
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>

#import <QuartzCore/QuartzCore.h>

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
                             const wxString& n,
                             bool only2d) : name(n.ToStdString())
{
    if (Create(parent, id, pos, size, wxFULL_REPAINT_ON_RESIZE | wxCLIP_CHILDREN | wxCLIP_SIBLINGS | style, name, only2d)) {

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

// Convenience accessor for the shared Metal state manager
static MetalDeviceManager& mgr() {
    return MetalDeviceManager::instance();
}

wxMetalCanvas::~wxMetalCanvas() {
    mgr().release();
}
MTKView* wxMetalCanvas::getMTKView() const {
    return (MTKView*)this->GetHandle();
}

id<MTLDevice> wxMetalCanvas::getMTLDevice() {
    return mgr().getMTLDevice();
}
id<MTLLibrary> wxMetalCanvas::getMTLLibrary() {
    return mgr().getMTLLibrary();
}
id<MTLDepthStencilState> wxMetalCanvas::getDepthStencilStateLE() {
    return mgr().getDepthStencilStateLE();
}
id<MTLDepthStencilState> wxMetalCanvas::getDepthStencilStateL() {
    return mgr().getDepthStencilStateL();
}
id<MTLCommandQueue> wxMetalCanvas::getMTLCommandQueue() {
    return mgr().getMTLCommandQueue();
}
id<MTLCommandQueue> wxMetalCanvas::getBltCommandQueue() {
    return mgr().getBltCommandQueue();
}

int wxMetalCanvas::getMSAASampleCount() {
    return mgr().getMSAASampleCount();
}


bool wxMetalCanvas::Create(wxWindow *parent,
                           wxWindowID id,
                           const wxPoint& pos,
                           const wxSize& size,
                           long style,
                           const wxString& name,
                           bool only2d) {

    is3d = !only2d;
    usesMsaa = is3d;
    DontCreatePeer();

    if (!wxWindow::Create(parent, id, pos, size, style, name)) {
        return false;
    }

    mgr().retain();

    NSRect r = wxOSXGetFrameForControl(this, pos , size);
    wxCustomMTKView* v = [[wxCustomMTKView alloc] initWithFrame:r device:mgr().getMTLDevice()];
    [v retain];
    [v setPaused:true];
    [v setEnableSetNeedsDisplay:true];
    [v setColorPixelFormat:MTLPixelFormatBGRA8Unorm ];
    [v setClearColor:MTLClearColorMake(0, 0, 0, 1)];
    
    NSString *vname = [NSString stringWithUTF8String:name.c_str()];
    [[v layer] setName:vname];
    
    if (!only2d) {
        [v setSampleCount:mgr().getMSAASampleCount()];
        [v setDepthStencilPixelFormat:MTLPixelFormatDepth32Float];
    }

    wxWidgetCocoaImpl* c = new wxWidgetCocoaImpl( this, v, wxWidgetImpl::Widget_UserKeyEvents | wxWidgetImpl::Widget_UserMouseEvents );
    SetPeer(c);
    MacPostControlCreate(pos, size) ;
    return true;
}

id<MTLRenderPipelineState> wxMetalCanvas::getPipelineState(const std::string &n, const char *vShader, const char *fShader,
                                                           bool blending) {
    bool depth = RequiresDepthBuffer();
    bool msaa = usesMsaa || depth;
    MTLPixelFormat colorFormat = [getMTKView() colorPixelFormat];
    return mgr().getPipelineState(n, vShader, fShader, blending, depth, msaa, colorFormat);
}

 
void wxMetalCanvas::addToSyncPoint(id<MTLCommandBuffer> &buffer, id<CAMetalDrawable> &drawable) {
    if (!isUsingPresentTime) {
        [buffer presentDrawable:drawable];
        [buffer commit];
    } else {
        [buffer presentDrawable:drawable atTime:nextPresentTime];
        [buffer commit];
        isUsingPresentTime = false;
    }
}

int wxMetalCanvas::getScreenIndex() const {
    NSScreen *scr = [getMTKView() window].screen;
    NSArray<NSScreen *> *screens = [NSScreen screens];
    for (NSUInteger i = 0; i < screens.count; i++) {
        if (screens[i] == scr) {
            return i;
        }
    }
    return 0;
}
bool wxMetalCanvas::startFrameForTime(double ts) {
    if (ts > nextPresentTime) {
        nextPresentTime = ts;
        isUsingPresentTime = true;
        return true;
    }
    return false;
}

