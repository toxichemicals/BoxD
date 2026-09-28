all:
	crystal build box.cr
	crystal build boxd.cr

release:
	crystal build --release box.cr
	crystal build --release boxd.cr

clean:
	rm -f box boxd services.db

.PHONY: all release clean

