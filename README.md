Module Tools
=======================================

This package contains convenient command line tools for Znuny development.

Installation
------------

To install the required Perl modules, you can use:

    cd /path/to/module-tools
    cpanm --installdeps .

Then please copy the default configuration and change it with your data:

    cd /path/to/module-tools
    cp  ./etc/config.pl.dist ./etc/config.pl
    vim ./etc/config.pl

Developer operation
-------------------

Developers can use the tools by invoking console command under OTRS user:

    # Get command overview
    sudo -u otrs /path/to/module-tools/bin/otrs.ModuleTools.pl

    # Install test instance
    sudo -u otrs /path/to/module-tools/bin/otrs.ModuleTools.pl TestSystem::Instance::Setup --framework-directory /path/to/otrs --fred-directory /path/to/Fred

On some systems it may be required to run instance setup as root user:

    # Install test instance of OTRS as root
    sudo /path/to/module-tools/bin/otrs.ModuleTools.pl TestSystem::Instance::Setup --allow-root --framework-directory /path/to/otrs --fred-directory /path/to/Fred
