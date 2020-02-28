# -------------------------------------------------------------------------------------------------
# <copyright file="mocks.pxd" company="Nautech Systems Pty Ltd">
#  Copyright (C) 2015-2020 Nautech Systems Pty Ltd. All rights reserved.
#  The use of this source code is governed by the license as found in the LICENSE.md file.
#  https://nautechsystems.io
# </copyright>
# -------------------------------------------------------------------------------------------------

cdef class ObjectStorer:
    cdef list _store
    cdef readonly int count

    cpdef list get_store(self)
    cpdef void store(self, object obj)
    cpdef void store_2(self, object obj1, object obj2)
