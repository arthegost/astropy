# cython: profile=True
# Licensed under a 3-clause BSD style license - see LICENSE.rst

import numpy as np
cimport numpy as np
from numpy import ma
from ...utils.data import get_readable_fileobj
from ...extern import six

cdef extern from "src/tokenizer.h":
    ctypedef enum tokenizer_state:
        START_LINE
        START_FIELD
        START_QUOTED_FIELD
        FIELD
        QUOTED_FIELD
        QUOTED_FIELD_NEWLINE
        COMMENT

    ctypedef enum err_code:
        NO_ERROR
        INVALID_LINE
        TOO_MANY_COLS
        NOT_ENOUGH_COLS
        CONVERSION_ERROR

    ctypedef struct tokenizer_t:
        char *source        # single string containing all of the input
        int source_len         # length of the input
        int source_pos        # current index in source for tokenization
        char delimiter        # delimiter character
        char comment        # comment character
        char quotechar        # quote character
        char *header_output # string containing header data
        char **output_cols    # array of output strings for each column
        char **col_ptrs     # array of pointers to current output position for each col
        int *output_len        # length of each output column string
        int header_len      # length of the header output string
        int num_cols        # number of table columns
        int num_rows        # number of table rows
        int fill_extra_cols # represents whether or not to fill rows with too few values
        tokenizer_state state   # current state of the tokenizer
        err_code code        # represents the latest error that has occurred
        int iter_col        # index of the column being iterated over
        char *curr_pos      # current iteration position
        char *buf           # buffer for misc. data
        # Example input/output
        # --------------------
        # source: "A,B,C\n10,5.,6\n1,2,3"
        # output_cols: ["A\x0010\x001", "B\x005.\x002", "C\x006\x003"]

    tokenizer_t *create_tokenizer(char delimiter, char comment, char quotechar, int fill_extra_cols)
    void delete_tokenizer(tokenizer_t *tokenizer)
    int tokenize(tokenizer_t *self, int start, int end, int header, int *use_cols, int use_cols_len)
    int int_size()
    int str_to_int(tokenizer_t *self, char *str)
    float str_to_float(tokenizer_t *self, char *str)
    void start_iteration(tokenizer_t *self, int col)
    int finished_iteration(tokenizer_t *self)
    char *next_field(tokenizer_t *self)

class CParserError(Exception):
    """
    An instance of this class is thrown when an error occurs
    during C parsing.
    """

ERR_CODES = dict(enumerate([
    "no error",
    "invalid line supplied",
    lambda line: "too many columns found in line {0} of data".format(line),
    lambda line: "not enough columns found in line {0} of data".format(line),
    "type conversion error"
    ]))

cdef class CParser:
    """
    A fast Cython parser class which uses underlying C code
    for tokenization.
    """

    cdef:
        tokenizer_t *tokenizer
        object source
        object header_start
        int data_start
        int data_end
        object data_end_obj
        object include_names
        object exclude_names
        object fill_values
        object fill_include_names
        object fill_exclude_names
        object fill_names
        int fill_extra_cols
        np.ndarray use_cols

    cdef public:
        int width
        object names

    def __cinit__(self, source,
                  delimiter=',',
                  comment=None,
                  quotechar='"',
                  header_start=0,
                  data_start=1,
                  data_end=None,
                  names=None,
                  include_names=None,
                  exclude_names=None,
                  fill_values=('', '0'),
                  fill_include_names=None,
                  fill_exclude_names=None,
                  fill_extra_cols=0):

        self.tokenizer = create_tokenizer(ord(delimiter), ord(comment), ord(quotechar), fill_extra_cols)
        self.source = None
        self.setup_tokenizer(source)
        self.header_start = header_start
        self.data_start = data_start
        self.data_end = -1 # keep reading data until the end
        if data_end is not None and data_end >= 0:
            self.data_end = data_end
        self.data_end_obj = data_end
        self.names = names
        self.include_names = include_names
        self.exclude_names = exclude_names
        if len(fill_values) > 0 and isinstance(fill_values[0], six.string_types):
            self.fill_values = [fill_values]
        else:
            self.fill_values = fill_values
        try:
            # Create a dict with the values to be replaced as keys
            self.fill_values = dict([(l[0].encode('utf-8'), l[1:]) for l in self.fill_values])
        except IndexError:
            raise ValueError("Format of fill_values must be "
                             "(<bad>, <fill>, <optional col1>, ...)")
        self.fill_include_names = fill_include_names
        self.fill_exclude_names = fill_exclude_names
        self.fill_extra_cols = fill_extra_cols
    
    def __dealloc__(self):
        if self.tokenizer:
            delete_tokenizer(self.tokenizer)

    cdef raise_error(self, msg):
        err_msg = ERR_CODES.get(self.tokenizer.code, "unknown error")
        if callable(err_msg):
            err_msg = err_msg(self.tokenizer.num_rows + 1)
        raise CParserError("{0}: {1}".format(msg, err_msg))

    cdef setup_tokenizer(self, source):
        cdef char *src

        if isinstance(source, six.string_types) or hasattr(source, 'read'):
            #todo: handle the case where source is the actual data (includes newline)
            with get_readable_fileobj(source) as file_obj:
                source = file_obj.read()
        else:
            try:
                source = '\n'.join(source) # iterable sequence of lines
            except TypeError:
                raise TypeError('Input "table" must be a file-like object, a string (filename'
                             'or data), or an iterable')
        # Create a reference to the Python object so its char * pointer remains valid
        self.source = source + '\n' # add newline to simplify handling last line of data
        self.source = self.source.encode('ascii') # encode in ASCII for char * handling (fixes Python 3 issue)
        src = self.source
        self.tokenizer.source = src
        self.tokenizer.source_len = len(self.source)

    def read_header(self):
        if self.names:
            self.width = len(self.names)
        # header_start is a valid line number
        elif self.header_start is not None and self.header_start >= 0:
            if tokenize(self.tokenizer, self.header_start, -1, 1, <int *> 0, 0) != 0:
                self.raise_error("an error occurred while tokenizing the header line")
            self.names = []
            name = ''
            for i in range(self.tokenizer.header_len):
                c = self.tokenizer.header_output[i]
                if not c:
                    if name:
                        self.names.append(name.replace('\x01', ''))
                        name = ''
                    else:
                        break # end of string
                else:
                    name += chr(c)
            self.width = len(self.names)
        else:
            # Get number of columns from first data row
            if tokenize(self.tokenizer, 0, -1, 1, <int *> 0, 0) != 0:
                self.raise_error("an error occurred while tokenizing the first line of data")
            self.width = 0
            for i in range(self.tokenizer.header_len):
                if not self.tokenizer.header_output[i]:
                    if i > 0 and self.tokenizer.header_output[i - 1]:
                        self.width += 1
                    else:
                        break
            self.names = ['col{0}'.format(i + 1) for i in range(self.width)] # auto-generate names

        size = int_size()
        dtype = np.int16 #TODO: maybe find a better way to do this?
        if size == 64:
            dtype = np.int64
        elif size == 32:
            dtype = np.int32
        self.use_cols = np.ones(self.width, dtype)
        if self.include_names is not None:
            for i, name in enumerate(self.names):
                if name not in self.include_names:
                    self.use_cols[i] = 0
        if self.exclude_names is not None:
            for name in self.exclude_names:
                try:
                    self.use_cols[self.names.index(name)] = 0
                except ValueError: # supplied name is invalid, ignore
                    continue

        self.names = [self.names[i] for i, should_use in enumerate(self.use_cols) if should_use]
        self.width = len(self.names)
        self.tokenizer.num_cols = self.width
            
    def read(self):
        if tokenize(self.tokenizer, self.data_start, self.data_end, 0,
                    <int *> self.use_cols.data, len(self.use_cols)) != 0:
            self.raise_error("an error occurred while tokenizing data")
        else:
            self._set_fill_names()
            return self._convert_data()

    cdef _set_fill_names(self):
        self.fill_names = set(self.names)
        if self.fill_include_names is not None:
            self.fill_names.intersection_update(self.fill_include_names)
        if self.fill_exclude_names is not None:
            self.fill_names.difference_update(self.fill_exclude_names)

    cdef _convert_data(self):
        cdef int num_rows = self.tokenizer.num_rows
        if self.data_end_obj is not None and self.data_end_obj < 0:
            num_rows += self.data_end_obj
        cols = {}

        for i, name in enumerate(self.names):
            try:
                cols[name] = self.convert_int(i, num_rows)
            except ValueError:
                try:
                    cols[name] = self.convert_float(i, num_rows)
                except ValueError:
                    cols[name] = self.convert_str(i, num_rows)

        return cols

    cdef np.ndarray convert_int(self, i, num_rows):
        cdef np.ndarray col = np.empty(num_rows, dtype=np.int_)
        cdef int converted
        cdef int row = 0
        cdef int *data = <int *> col.data
        cdef bytes field
        cdef bytes new_val
        mask = set()

        start_iteration(self.tokenizer, i)
        while not finished_iteration(self.tokenizer):
            if row == num_rows:
                break
            field = next_field(self.tokenizer)
            if field in self.fill_values:
                new_val = str(self.fill_values[field][0]).encode('utf-8')
                if (len(self.fill_values[field]) > 1 and self.names[i] in self.fill_values[field][1:]) or \
                           (len(self.fill_values[field]) == 1 and self.names[i] in self.fill_names):
                    mask.add(row)
                converted = str_to_int(self.tokenizer, new_val)
            else:
                converted = str_to_int(self.tokenizer, field)

            if self.tokenizer.code == CONVERSION_ERROR:
                self.tokenizer.code = NO_ERROR
                raise ValueError()
            col[row] = converted
            row += 1

        if mask:
            return ma.masked_array(col, mask=[1 if i in mask else 0 for i in range(row)])
        else:
            return col

    cdef np.ndarray convert_float(self, i, num_rows):
        cdef np.ndarray col = np.empty(num_rows, dtype=np.float_)
        cdef float converted
        cdef int row = 0
        cdef float *data = <float *> col.data
        cdef bytes field
        cdef bytes new_val
        mask = set()

        start_iteration(self.tokenizer, i)
        while not finished_iteration(self.tokenizer):
            if row == num_rows:
                break
            field = next_field(self.tokenizer)
            if field in self.fill_values:
                new_val = str(self.fill_values[field][0]).encode('utf-8')
                if (len(self.fill_values[field]) > 1 and self.names[i] in self.fill_values[field][1:]) or \
                           (len(self.fill_values[field]) == 1 and self.names[i] in self.fill_names):
                    mask.add(row)
                converted = str_to_float(self.tokenizer, new_val)
            else:
                converted = str_to_float(self.tokenizer, field)

            if self.tokenizer.code == CONVERSION_ERROR:
                self.tokenizer.code = NO_ERROR
                raise ValueError()
            col[row] = converted
            row += 1

        if mask:
            return ma.masked_array(col, mask=[1 if i in mask else 0 for i in range(row)])
        else:
            return col

    cdef np.ndarray convert_str(self, i, num_rows):
        cdef np.ndarray col = np.empty(num_rows, dtype=object) # TODO: find a faster method here
        cdef int row = 0
        cdef bytes field
        cdef bytes new_val
        mask = set()

        start_iteration(self.tokenizer, i)
        while not finished_iteration(self.tokenizer):
            if row == num_rows:
                break
            field = next_field(self.tokenizer)
            if field in self.fill_values:
                new_val = str(self.fill_values[field][0]).encode('utf-8')
                if (len(self.fill_values[field]) > 1 and self.names[i] in self.fill_values[field][1:]) or \
                           (len(self.fill_values[field]) == 1 and self.names[i] in self.fill_names):
                    mask.add(row)
                col[row] = new_val.decode('utf-8')
            else:
                col[row] = field.decode('utf-8')
            row += 1

        if mask:
            return ma.masked_array(col, mask=[1 if i in mask else 0 for i in range(row)])
        else:
            return col
