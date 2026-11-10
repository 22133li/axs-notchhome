DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets with the PreferenceBundle.
include AxsNotchHomeBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsNotchHome
AxsNotchHome_FILES = $(wildcard Hooks/*.xm Sources/*.m)
AxsNotchHome_CFLAGS = -fobjc-arc -I./Headers -I./Sources
AxsNotchHome_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsNotchHome_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk


