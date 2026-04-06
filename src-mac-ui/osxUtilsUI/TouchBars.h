#pragma once

#include <wx/event.h>
#include <wx/colour.h>
#include <wx/bitmap.h>
#include <string>
#include <vector>

class wxBitmap;
class wxWindow;
class xlTouchBar;

class EffectManager;
class MainSequencer;
class TouchBarContollerData;
class TouchBarItemData;

#define __XLIGHTS_HAS_TOUCHBARS__

class xlTouchBarSupport {
public:
    xlTouchBarSupport();
    ~xlTouchBarSupport();


    void Init(wxWindow *w);

    bool HasTouchBar() { return controllerData != nullptr; }

    wxWindow *GetWindow() { return window; }
    wxWindow *GetControlParent() { return parent; }

    void SetActive(xlTouchBar *tb);
    bool IsActive(xlTouchBar *tb) {
        return currentBar == tb;
    }
    xlTouchBar *GetCurrentBar() const {return currentBar;};

private:
    wxWindow *window;
    wxWindow *parent;
    TouchBarContollerData *controllerData;
    xlTouchBar *currentBar;
};


class TouchBarItem {
public:
    TouchBarItem(const std::string &n) : name(n),  data(nullptr) {}
    virtual ~TouchBarItem();

    const std::string &GetName() const {return name;}

    TouchBarItemData *GetData();
protected:
    std::string name;
    mutable TouchBarItemData *data;
};

class wxControlTouchBarItem : public TouchBarItem {
public:
    wxControlTouchBarItem(wxWindow *c);
    virtual ~wxControlTouchBarItem() {}

    wxWindow *GetControl() const { return control; }
private:
    wxWindow *control;
};

typedef std::function<void(void)> ButtonTouchBarItemClicked;
class ButtonTouchBarItem : public TouchBarItem {
public:
    ButtonTouchBarItem(ButtonTouchBarItemClicked cb, const std::string &n, const std::string &l)
        : TouchBarItem(n), callback(cb), label(l), backgroundColor(0, 0, 0, 0) {};
    ButtonTouchBarItem(ButtonTouchBarItemClicked cb, const std::string &n, const wxBitmapBundle &l)
        : TouchBarItem(n), callback(cb), bmp(l), backgroundColor(0, 0, 0, 0)  {};
    virtual ~ButtonTouchBarItem() {}

    virtual void Clicked() {
        callback();
    }

    void SetBackgroundColor(const wxColor &c) {backgroundColor = c;}


    const std::string &GetLabel() const { return label; };
    const wxBitmapBundle &GetBitmap() const { return bmp; };
    const wxColor GetBackgroundColor() const {return backgroundColor;};
protected:
    ButtonTouchBarItemClicked callback;
    std::string label;
    wxBitmapBundle bmp;
    wxColor backgroundColor;
};

class GroupTouchBarItem : public TouchBarItem {
public:
    GroupTouchBarItem(const std::string &n, const std::vector<ButtonTouchBarItem*> i) : TouchBarItem(n), items(i) {}
    virtual ~GroupTouchBarItem();
    
    virtual const std::vector<ButtonTouchBarItem*> &GetItems() { return items; }
    
    void AddItem(ButtonTouchBarItem* i) { items.push_back(i); }
protected:
    std::vector<ButtonTouchBarItem*> items;
};

typedef std::function<void(wxColor)> ColorPickerItemChangedFunction;
class ColorPickerItem : public TouchBarItem {
public:
    ColorPickerItem(ColorPickerItemChangedFunction f,const std::string &n) : TouchBarItem(n), callback(f) {}
    virtual ~ColorPickerItem() {};

    void SetColor(const wxBitmap &b, wxColor &c);

    wxBitmap &GetBitmap() { return bmp;}
    wxColor &GetColor() {return color;}
    ColorPickerItemChangedFunction &GetCallback() {return callback;};
private:
    ColorPickerItemChangedFunction callback;
    wxBitmap bmp;
    wxColor color;
};


typedef std::function<void(int)> SliderItemChangedFunction;
class SliderItem : public TouchBarItem {
public:
    SliderItem(SliderItemChangedFunction f,
               const std::string &n,
               int mn, int mx) : TouchBarItem(n), callback(f), value(mn), min(mn), max(mx) {}
    virtual ~SliderItem() {};

    void SetValue(int i);
    int GetValue() const { return value; }
    int GetMin() const { return min;}
    int GetMax() const { return max;}

    SliderItemChangedFunction &GetCallback() {return callback;}
private:
    SliderItemChangedFunction callback;
    int value;
    int min;
    int max;
};


class xlTouchBar : public wxEvtHandler {
public:
    xlTouchBar(xlTouchBarSupport &support);
    xlTouchBar(xlTouchBarSupport &support, std::vector<TouchBarItem*> &i);
    virtual ~xlTouchBar();

    virtual void SetActive() { support.SetActive(this); }

    virtual bool IsCustomizable() { return false; }
    virtual const std::vector<TouchBarItem*> &GetItems() { return items; }
    virtual const std::vector<TouchBarItem*> &GetDefaultItems() { return GetItems(); }

    virtual std::string GetName() = 0;
    virtual bool ShowEsc() { return true; }
protected:
    xlTouchBarSupport &support;
    std::vector<TouchBarItem*> items;
};

typedef std::function<void(int, wxColor)> ColorChangedFunction;
class ColorPanelTouchBar : public xlTouchBar {
public:
    ColorPanelTouchBar(ColorChangedFunction f,
                       SliderItemChangedFunction spark,
                       xlTouchBarSupport &support);
    virtual ~ColorPanelTouchBar();

    virtual std::string GetName() override { return "ColorBar";}

    void SetColor(int idx, const wxBitmap &bmp, wxColor &c);
    void SetSparkles(int v);

    virtual void SetActive() override;

private:
    ColorChangedFunction colorCallback;
    SliderItemChangedFunction sparkCallback;
    xlTouchBar *lastBar;
    bool inCallback;
};


class EffectGridTouchBar : public xlTouchBar {
public:
    EffectGridTouchBar(xlTouchBarSupport &support, std::vector<TouchBarItem*> &i);
    virtual ~EffectGridTouchBar();

    virtual std::string GetName() override { return "EffectGrid";}
    virtual bool IsCustomizable() override { return true; }

private:
};
