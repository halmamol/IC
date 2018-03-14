import tables as tb

from .. reco import tbl_functions as tbl


def hist_writer(file,
                *,
                group_name  : 'options: HIST, HIST2D',
                table_name  : 'options: pmt, pmtMAU, sipm, sipmMAU',
                compression = 'ZLIB4',
                n_sensors   : 'number of pmts or sipms',
                n_bins      : 'length of bin range used',
                bin_centres : 'np.array of bin centres'):
    try:                       hist_group = getattr          (file.root, group_name)
    except tb.NoSuchNodeError: hist_group = file.create_group(file.root, group_name)

    hist_table = file.create_earray(hist_group,
                                    table_name,
                                    atom    = tb.Int32Atom(),
                                    shape   = (0, n_sensors, n_bins),
                                    filters = tbl.filters(compression))

    ## The bins can be written just once at definition of the writer
    file.create_array(hist_group, table_name+'_bins', bin_centres)

    def write_hist(histo : 'np.array: RWF, CWF, SiPM'):
        hist_table.append(histo.reshape(1, n_sensors, n_bins))

    return write_hist

def hist_writer_var(file, *, compression='ZLIB4'):

    def write_hist(group_name  : 'options: HIST, HIST2D',
                   table_name  : 'histogram name',
                   entries     : 'np.array with bin content',
                   bins        : 'list of np.array of bins',
                   out_of_range: 'np.array lenght=2 with events out of range',
                   errors      : 'np.array with bins uncertainties',
                   labels      : 'list with labels of the histogram'):

        try:                       hist_group = getattr          (file.root, group_name)
        except tb.NoSuchNodeError: hist_group = file.create_group(file.root, group_name)

        if table_name in hist_group:
            raise ValueError("Histogram {} already exists".format(table_name))

        add_carray(hist_group, table_name, entries)
        vlarray = file.create_vlarray(hist_group, table_name + '_bins', atom=tb.Float64Atom(shape = ()), filters=tbl.filters(compression))
        for ibin in bins:
            vlarray.append(ibin)
        add_carray(hist_group, table_name + '_outRange', out_of_range)
        add_carray(hist_group, table_name + '_errors', errors)
        file.create_array(hist_group, table_name + '_labels', labels)

    def add_carray(hist_group, table_name, var):
        array_atom  = tb.Atom.from_dtype(var.dtype)
        array_shape = var.shape
        entry = file.create_carray(hist_group, table_name, atom=array_atom, shape=array_shape, filters=tbl.filters(compression))
        entry[:] = var

    return write_hist
