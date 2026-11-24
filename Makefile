# ivLyrics for YouTube Music (iOS)
#
#   make package                      -> ivLyricsYTM.dylib (sideload / IPA injection, default)
#   make package JAILBREAK=1          -> .deb tweak for jailbroken devices
#   make package JAILBREAK=1 ROOTLESS=1

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = YouTubeMusic
PACKAGE_VERSION = 1.0.0

ifeq ($(ROOTLESS),1)
THEOS_PACKAGE_SCHEME = rootless
else ifeq ($(ROOTHIDE),1)
THEOS_PACKAGE_SCHEME = roothide
endif

include $(THEOS)/makefiles/common.mk

ifeq ($(JAILBREAK),1)
TWEAK_NAME = ivLyricsYTM
else
LIBRARY_NAME = ivLyricsYTM
endif

ivLyricsYTM_FILES = $(wildcard Sources/*.x) $(wildcard Sources/*.m)
ivLyricsYTM_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-format-nonliteral -Wno-format-security -Wno-error -ISources -DIVL_VERSION=\"$(PACKAGE_VERSION)\"
ivLyricsYTM_FRAMEWORKS = UIKit Foundation QuartzCore CoreText NaturalLanguage
# Hooks use the ObjC runtime directly -> the dylib has no CydiaSubstrate/ElleKit dependency
ivLyricsYTM_LOGOS_DEFAULT_GENERATOR = internal

ifeq ($(JAILBREAK),1)
include $(THEOS_MAKE_PATH)/tweak.mk
else
ivLyricsYTM_INSTALL_PATH = /usr/lib
include $(THEOS_MAKE_PATH)/library.mk
endif
