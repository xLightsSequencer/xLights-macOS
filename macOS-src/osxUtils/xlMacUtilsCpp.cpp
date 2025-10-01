//
//  xlMacUtilsCpp.cpp
//  xLights-macOSLib
//
//  Created by Daniel Kulp on 6/16/25.
//  Copyright © 2025 Daniel Kulp. All rights reserved.
//

#include <stdio.h>
#include "../../xLights-macOSLib.build/DerivedSources/xLights_macOSLib-Swift.h"



static void loadGroupEntries(wxConfig *bookmarks, const std::string &pfx) {
    wxString entry;
    long idx;
    bool cont = bookmarks->GetFirstEntry(entry, idx);
    while (cont) {
        wxString data = bookmarks->Read(entry);
        std::string path = pfx + "/" + entry.ToStdString();
        xLights_macOSLib::addAccessibleURL(path, data.ToStdString());
        cont = bookmarks->GetNextEntry(entry, idx);
    }
    
    cont = bookmarks->GetFirstGroup(entry, idx);
    while (cont) {
        std::string p = bookmarks->GetPath();
        bookmarks->SetPath(entry + "/");
        loadGroupEntries(bookmarks, p + "/" + entry);
        bookmarks->SetPath(p);
        cont = bookmarks->GetNextGroup(entry, idx);
    }

}

bool ObtainAccessToURL(const std::string &path, bool enforceWritable = false) {
    static bool oldPrefsChecked = false;
    if (!oldPrefsChecked) {
        static std::mutex oldLock;
        std::unique_lock<std::mutex> lock(oldLock);
        if (!oldPrefsChecked) {
            wxConfig *bookmarks = new wxConfig("xLights-Bookmarks");
            loadGroupEntries(bookmarks, "");
            // At some point in the future when people aren't going back to old versions...
            //bookmarks->DeleteAll();
        }
        oldPrefsChecked = true;
    }
    return xLights_macOSLib::obtainAccessToURL(path, enforceWritable);
}

void GetAllFilesInDir(const wxString &dir, wxArrayString &files, const wxString &filespec, int flags) {
    if (flags == -1) {
        flags = wxDIR_FILES;
    }
    flags |= wxDIR_HIDDEN;
    static std::string iCloudExt = ".icloud";
    wxArrayString f2;
    std::set<wxString> allFiles;
    wxDir::GetAllFiles(dir, &f2, filespec, flags);
    if (filespec != "") {
        wxDir::GetAllFiles(dir, &f2, filespec + iCloudExt, flags);
    }
    for (auto &a : f2) {
        // this will remove duplicates that match both ext
        allFiles.insert(a);
    }
    for (auto &f : allFiles) {
        if (f.EndsWith(iCloudExt)) {
            int pos = f.find_last_of('/');
            wxString n = f.substr(0, pos + 1);
            n += f.substr(pos + 2, f.size() - 9 - pos);
            files.push_back(n);
        } else {
            files.push_back(f);
        }
    }
}

std::list<std::string> GetFileRevisions(const std::string &path) {
    swift::Array<swift::String> a = xLights_macOSLib::getFileRevisions(path);
    std::list<std::string> ret;
    for (int x = a.getStartIndex(); x < a.getEndIndex(); x++) {
        swift::String s = a[x];
        std::string s2 = s;
        ret.push_back(s2);
    }
    return ret;
}



extern "C" {
void AudioDeviceChangedCallback();
}


static std::function<void()> AUDIO_CALLBACK;
void AudioDeviceChangedCallback() {
    if (AUDIO_CALLBACK) {
        AUDIO_CALLBACK();
    }
}

void AddAudioDeviceChangeListener(std::function<void()> &&cb) {
    AUDIO_CALLBACK = cb;
    xLights_macOSLib::addAudioDeviceChangeListener();
}
void RemoveAudioDeviceChangeListener() {
    xLights_macOSLib::removeAudioDeviceChangeListener();
    AUDIO_CALLBACK = {};
}

void SetThreadQOS(int i) {
    if (i) {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    } else {
        pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);
    }
}
