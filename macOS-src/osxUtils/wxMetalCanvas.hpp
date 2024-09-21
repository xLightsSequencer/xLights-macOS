#include <wx/window.h>


#ifdef __OBJC__
#import <Foundation/Foundation.h>
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>
#else
class MTKView;
#endif


class wxMetalCanvas : public wxWindow {
public:
    wxMetalCanvas(wxWindow *parent,
                  wxWindowID id = wxID_ANY,
                  const wxPoint& pos = wxDefaultPosition,
                  const wxSize& size = wxDefaultSize,
                  long style = 0,
                  const wxString& name = "",
                  bool only2d = true);
    wxMetalCanvas(wxWindow *parent, const wxString& name) : wxMetalCanvas(parent, wxID_ANY, wxDefaultPosition, wxDefaultSize, 0, name) {}

    virtual ~wxMetalCanvas();

    const std::string &getName() const { return name; }

    int getScreenIndex() const;    
    bool startFrameForTime(double ts);
    void cancelFrameForTime();
    
#ifdef __OBJC__
    //methods only available from objective-c.  Cannot be virtual as they cannot be in the virtual function table
    static id<MTLDevice> getMTLDevice();
    static id<MTLLibrary> getMTLLibrary();
    static id<MTLDepthStencilState> getDepthStencilStateLE();
    static id<MTLDepthStencilState> getDepthStencilStateL();
    static id<MTLCommandQueue> getMTLCommandQueue();
    static int getMSAASampleCount();

    MTKView* getMTKView() const;
    id<MTLRenderPipelineState> getPipelineState(const std::string &name, const char *vShader, const char *fShader,
                                                bool blending);

    void addToSyncPoint(id<MTLCommandBuffer> &buffer, id<CAMetalDrawable> &drawable);
#endif

    bool usesMSAA() { return usesMsaa; }
    virtual bool RequiresDepthBuffer() const { return false; }
        
protected:
    DECLARE_EVENT_TABLE()

    bool Create(wxWindow *parent,
                wxWindowID id = wxID_ANY,
                const wxPoint& pos = wxDefaultPosition,
                const wxSize& size = wxDefaultSize,
                long style = 0,
                const wxString& name = "",
                bool only2d = true);

    bool is3d = false;
    bool usesMsaa = false;
    std::string name;
    
    double nextPresentTime = 0;
    bool   isUsingPresentTime = false;
private:
    static bool inSyncPoint;
};
