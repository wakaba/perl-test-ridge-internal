all: 

# ------ Setup ------

WGET = wget
GIT = git

deps: git-submodules pmbp-install

git-submodules:
	$(GIT) submodule update --init

local/bin/pmbp.pl:
	mkdir -p local/bin
	$(WGET) -O $@ https://github.com/wakaba/perl-setupenv/raw/master/bin/pmbp.pl

pmbp-upgrade: local/bin/pmbp.pl
	perl local/bin/pmbp.pl --update-pmbp-pl

pmbp-update: pmbp-upgrade
	perl local/bin/pmbp.pl --update

pmbp-install: pmbp-upgrade
	perl local/bin/pmbp.pl --install \
            --create-perl-command-shortcut perl \
            --create-perl-command-shortcut prove \
            --add-to-gitignore /perl \
            --add-to-gitignore /prove

# ------ Tests ------

PERL = ./perl
PROVE = ./prove

test: test-deps safetest

test-deps: deps

safetest:
	$(PROVE) t/syntax.t

always:
