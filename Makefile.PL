# -*- mode: perl -*-
# ============================================================================
# $Id: Makefile.PL,v 4.5 2003/08/29 11:40:00 sparsons Exp $
# Makefile for the Perl module Net::Dev::Tools::MIB::MIBLoadOrder.
# Copyright (c) 1998-2003  Scott Parsons <sparsons@cpan.org>
# All rights reserved.
# This program is free software; you may redistribute it and/or modify it
# under the same terms as Perl itself.
# ============================================================================

eval { require 5.6.0 } or die <<'EOD'; 

   Net::Dev requires Perl 5.6.0

EOD

use ExtUtils::MakeMaker qw(WriteMakefile);

WriteMakefile(
   AUTHOR        => 'Scott Parsons <sparsons@cpan.org>',
   ABSTRACT      => 'Determine MIB load order for NMS',
   NAME          => 'Net::Dev::Tools::MIB::MIBLoadOrder',
   DISTNAME      => 'Net-Dev-MIBLoadOrder',
   VERSION       => '0.9.0',
   dist          => { 
      CI       => 'ci -u -m\"Changes for v$(VERSION)\"',
      COMPRESS => 'gzip --best', 
      SUFFIX   => 'gz',
      TAR      => 'tar',
      TARFLAGS => 'cvf', 
   },
);

exit 0;

