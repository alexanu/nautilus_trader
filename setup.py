#!/usr/bin/env python3
# -------------------------------------------------------------------------------------------------
#  Copyright (C) 2015-2020 Nautech Systems Pty Ltd. All rights reserved.
#  https://nautechsystems.io
#
#  Licensed under the GNU Lesser General Public License Version 3.0 (the "License");
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at https://www.gnu.org/licenses/lgpl-3.0.en.html
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
# -------------------------------------------------------------------------------------------------

import setuptools
from setuptools import setup
from Cython.Build import cythonize, build_ext
from Cython.Compiler import Options

from nautilus_trader import __author__, __version__
from tools.packaging import parse_requirements, make_extensions


PACKAGE_NAME = 'nautilus_trader'
MAINTAINER = __author__
MAINTAINER_EMAIL = 'info@nautechsystems.io'
DESCRIPTION = 'An algorithmic trading platform and event-driven backtester'
URL = 'https://github.com/nautechsystems/nautilus_trader'
PYTHON_REQUIRES = '>=3.6'
DIRECTORIES_TO_CYTHONIZE = [PACKAGE_NAME]
PACKAGE_DATA_EXTENSIONS = ['*.csv', '*.pxd']


# Cython build options (edit here only)
# -------------------------------------
# Create a html annotations file for each .pyx
Options.annotate = True

# Embed docstrings in extensions
Options.embed_pos_in_docstring = True

# Treat compiler warnings as errors
Options.warning_errors = True

# Allows cimporting from a pyx file without a pxd file
Options.cimport_from_pyx = True

# Write profiling hooks into methods (x2 overhead, use for profiling only)
Profile_Hooks = False

# Cython compiler directives
compiler_directives = {
    'language_level': 3,         # If Python 3
    'cdivision': True,           # If division is as per C with no check for zero (35% speed up)
    'embedsignature': True,      # If docstrings should be embedded into C signatures
    'emit_code_comments': True,  # If comments should be emitted to generated C code
    'profile': Profile_Hooks     # See above
}
# -------------------------------------

packages = [module for module in setuptools.find_packages()]
package_data = {module: PACKAGE_DATA_EXTENSIONS for module in packages}

with open('README.md', encoding='utf-8') as f:
    LONG_DESCRIPTION = f.read()


setup(
    name=PACKAGE_NAME,
    version=__version__,
    author=__author__,
    maintainer=MAINTAINER,
    maintainer_email=MAINTAINER_EMAIL,
    description=DESCRIPTION,
    long_description=LONG_DESCRIPTION,
    long_description_content_type='text/markdown',
    classifiers=[
        'Development Status :: 5 - Production/Stable',
        'License :: OSI Approved :: GNU Lesser General Public License v3 or later (LGPLv3+)',
        'Programming Language :: Python :: 3',
        'Programming Language :: Python :: 3.6',
        'Programming Language :: Python :: 3.7',
        'Programming Language :: Python :: 3.8',
    ],
    url=URL,
    python_requires=PYTHON_REQUIRES,
    requires=parse_requirements('requirements.txt', strip=True),
    install_requires=parse_requirements('requirements.txt'),
    tests_require=parse_requirements('requirements.txt'),
    packages=packages,
    package_data=package_data,
    include_package_data=True,
    ext_modules=cythonize(
        module_list=make_extensions(DIRECTORIES_TO_CYTHONIZE),
        compiler_directives=compiler_directives,
        build_dir='build'),
    cmdclass={'build_ext': build_ext},
    options={'build_ext': {'inplace': True, 'force': False}},
    zip_safe=False  # Allows cimport of pxd files
)
