ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
  TARGET       := iphone:clang:latest:15.0
  ARCHS        := arm64 arm64e
  _PKG_ARCH    := iphoneos-arm64
  _PKG_DEPENDS := ellekit | mobilesubstrate, firmware (>= 15.0)
else
  TARGET       := iphone:clang:latest:14.0
  ARCHS        := arm64 arm64e
  _PKG_ARCH    := iphoneos-arm
  _PKG_DEPENDS := mobilesubstrate (>= 0.9.5000), firmware (>= 14.0)
endif

# INSTALL_TARGET_PROCESSES is a post-install respring hint only — it is NOT the
# injection scope. Injection scope is governed by TouchSimulator.plist Filter
# (com.apple.UIKit), which loads the dylib into every UIKit app.
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TouchSimulator

TouchSimulator_FILES = TouchSimulator.xm Example.xm
TouchSimulator_CFLAGS = -fobjc-arc -Wno-error -Wno-module-import-in-extern-c

TouchSimulator_FRAMEWORKS = UIKit IOSurface
TouchSimulator_PRIVATE_FRAMEWORKS = IOKit
TouchSimulator_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# Post-include: override arch that deb.mk:26 set from the control placeholder.
# _THEOS_DEB_PACKAGE_FILENAME is lazy (=) per deb.mk:59, so this flows through
# to the output filename.
THEOS_PACKAGE_ARCH := $(_PKG_ARCH)

# Rewrite the staged control's Architecture + Depends lines before packaging.
# sed -i.bak form works on both BSD (macOS) and GNU sed.
before-package::
	@sed -i.bak -e 's@^Architecture:.*@Architecture: $(_PKG_ARCH)@' \
	             -e 's@^Depends:.*@Depends: $(_PKG_DEPENDS)@' \
	             '$(THEOS_STAGING_DIR)/DEBIAN/control'
	@rm -f '$(THEOS_STAGING_DIR)/DEBIAN/control.bak'

# Debug helper: `make print-FOO` prints `FOO = <value>`.
# Used by AC-10: make print-THEOS_PACKAGE_INSTALL_PREFIX THEOS_PACKAGE_SCHEME=rootless
print-%:
	@echo $* = $($*)

rm:
	rm -rf .theos
	rm -rf packages
