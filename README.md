Module Tools
=======================================

This package contains convenient command line tools for Znuny development.

Installation
------------

To install the required Perl modules, you can use:

    cd /path/to/module-tools
    cpanm --installdeps .

or install them with help of Debian packages:

    sudo apt install libdatetime-perl libgetopt-complete-perl libio-interactive-perl libstring-similarity-perl libxmlrpc-lite-perl

Then please copy the default configuration and change it with your data:

    cd /path/to/module-tools
    cp  ./etc/config.pl.dist ./etc/config.pl
    vim ./etc/config.pl

Developer operation
-------------------

Developers can use the tools by invoking console command under Znuny user:

    # Get command overview
    sudo -u znuny /path/to/module-tools/bin/znuny.ModuleTools.pl

    # Install test instance
    sudo -u znuny /path/to/module-tools/bin/znuny.ModuleTools.pl TestSystem::Instance::Setup --framework-directory /path/to/znuny --fred-directory /path/to/Fred

On some systems it may be required to run instance setup as root user:

    # Install test instance of Znuny as root
    sudo /path/to/module-tools/bin/znuny.ModuleTools.pl TestSystem::Instance::Setup --allow-root --framework-directory /path/to/znuny --fred-directory /path/to/Fred
