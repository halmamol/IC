# Clsses defining the event model

cimport numpy as np
import numpy as np

from .. types.ic_types_c       cimport minmax
from .. core.exceptions        import PeakNotFound
from .. core.exceptions        import SipmEmptyList
from .. core.exceptions        import SipmNotFound
from .. core.core_functions    import loc_elem_1d
from .. core.exceptions        import InconsistentS12dPmtsd
from .. core.system_of_units_c import units


cdef class Peak:
    """Transient class representing a Peak.

    A Peak is represented as a pair of arrays:
    t: np.array() describing time bins
    E: np.array() describing energy.
    """

    def __init__(self, np.ndarray[double, ndim=1] t,
                       np.ndarray[double, ndim=1] E):

        cdef int i_t
        assert len(t) == len(E)
        self.t              = t
        self.E              = E
        self.height         = np.max(self.E)
        self.width          = self.t[-1] - self.t[0]
        self.total_energy   = np.sum(self.E)

        i_t    = (loc_elem_1d(self.E, self.height)
                             if self.total_energy > 0
                             else 0)

        self.tpeak  =  self.t[i_t]

    property tmin_tmax:
        def __get__(self): return minmax(self.t[0], self.t[-1])

    property number_of_samples:
        def __get__(self): return len(self.t)

    property good_waveform:
        def __get__(self):  return (False
                                    if np.any(np.isnan(self.t))  or
                                       np.any(np.isnan(self.E))
                                    else True)

    def total_energy_above_trheshold(self, thr):
        eth = self.E[self.E > thr]
        if len(eth):
            return np.sum(eth)
        else:
            return 0

    def width_above_trheshold(self, thr):
        eth = self.E[self.E > thr]
        if len(eth):
            t0 = (loc_elem_1d(self.E, eth[0])
              if self.total_energy > 0
              else 0)
            t1 = (loc_elem_1d(self.E, eth[-1])
              if self.total_energy > 0
              else 0)
            return self.t[t1] - self.t[t0]
        else:
            return 0

    def height_above_trheshold(self, thr):
        eth = self.E[self.E > thr]
        if len(eth):
            return np.max(eth)
        else:
            return 0


    def __str__(self):
        s = """Peak(samples = {0:d} width = {1:8.1f} mus , energy = {2:8.1f} pes
        height = {3:8.1f} pes tmin-tmax = {4} mus """.format(self.number_of_samples,
        self.width / units.mus, self.total_energy, self.height,
        (self.tmin_tmax * (1 / units.mus)))
        return s

    def __repr__(self):
        return self.__str__()


cdef class S12:
    """Base class representing an S1/S2 signal
    The S12 attribute is a dictionary s12
    {i: Peak(t,E)}, where i is peak number.
    The notation _s12 is intended to make this
    class private (public classes s1 and s2 will
    extend it).
    The rationale to use s1 and s2 rather than a single
    class s12 to represent both s1 and s2 is that, although
    structurally identical, s1 and s2 represent quite
    different objects. In Particular an s2si is constructed
    with a s2 not a s1.
    An s12 is represented as a dictinary of Peaks.

    """
    def __init__(self, dict s12d):

        cdef int peak_no
        cdef np.ndarray[double, ndim=1] t
        cdef np.ndarray[double, ndim=1] E
        self.peaks = {}

        #print('s12d ={}'.format(s12d))
        for peak_no, (t, E) in s12d.items():
            #print('t ={}'.format(t))
            #print('E ={}'.format(E))
            assert len(t) == len(E)
            #p = Peak(t,E)
            #print('peak = {}'.format(p))

            self.peaks[peak_no] =  Peak(t, E)

    property number_of_peaks:
         def __get__(self): return len(self.peaks)

    cpdef peak_collection(self):
        try:
            return tuple(self.peaks.keys())
        except KeyError:
            raise PeakNotFound

    cpdef peak_waveform(self, int peak_number):
        try:
            return self.peaks[peak_number]
        except KeyError:
             raise PeakNotFound

    cpdef store(self, table, event_number):
        row = table.row
        for peak_number, peak in self.peaks.items():
            for t, E in zip(peak.t, peak.E):
                row["event"] = event_number
                row["peak"]  =  peak_number
                row["time"]  = t
                row["ene"]   = E
                row.append()


cdef class S1(S12):
    def __init__(self, s1d):
        self.s1d = s1d
        super(S1, self).__init__(s1d)

    def __str__(self):
        s =  "S1 (number of peaks = {})\n".format(self.number_of_peaks)
        s2 = ['peak number = {}: {} \n'.format(i,
                                    self.peak_waveform(i)) for i in self.peaks]
        return  s + ''.join(s2)

    def __repr__(self):
        return self.__str__()


cdef class S2(S12):
    def __init__(self, s2d):
        self.s2d = s2d
        super(S2, self).__init__(s2d)

    def __str__(self):
        s =  "S2 (number of peaks = {})\n".format(self.number_of_peaks)
        s2 = ['peak number = {}: {} \n'.format(i,
                                    self.peak_waveform(i)) for i in self.peaks]
        return  s + ''.join(s2)

    def __repr__(self):
        return self.__str__()


cpdef check_s2d_and_s2sid_share_peaks(dict s2d, dict s2sid):
    cdef dict s2d_shared_peaks = {}
    cdef int pn
    for pn, peak in s2d.items():
        if pn in s2sid:
          s2d_shared_peaks[pn] = peak

    return s2d_shared_peaks


cdef class S2Si(S2):
    """Transient class representing the combination of
    S2 and the SiPM information.
    Notice that S2Si is constructed using an s2d and an s2sid.
    The s2d is an s12 dictionary (not an S2 instance)
    The s2sid is a dictionary {peak:{nsipm:[E]}}
    """

    def __init__(self, s2d, s2sid):
        """where:
           s2d   = {peak_number:[[t], [E]]}
           s2sid = {peak:{nsipm:[Q]}}
           Q is the energy in each SiPM sample
        """

        S2.__init__(self, check_s2d_and_s2sid_share_peaks(s2d, s2sid))
        self.s2sid = s2sid

    cpdef number_of_sipms_in_peak(self, int peak_number):
        return len(self.s2sid[peak_number])

    cpdef sipms_in_peak(self, int peak_number):
        try:
            return tuple(self.s2sid[peak_number].keys())
        except KeyError:
            raise PeakNotFound

    cpdef sipm_waveform(self, int peak_number, int sipm_number):
        cdef double [:] E
        if self.number_of_sipms_in_peak(peak_number) == 0:
            raise SipmEmptyList
        try:
            E = self.s2sid[peak_number][sipm_number]
            #print("in sipm_waveform")
            #print('t ={}'.format(self.peak_waveform(peak_number).t))
            #print('E ={}'.format(np.asarray(E)))
            return Peak(self.peak_waveform(peak_number).t, np.asarray(E))
        except KeyError:
            raise SipmNotFound

    cpdef sipm_waveform_zs(self, int peak_number, int sipm_number):
        cdef double [:] E, t, tzs, Ezs
        cdef list TZS = []
        cdef list EZS = []
        cdef int i
        if self.number_of_sipms_in_peak(peak_number) == 0:
            raise SipmEmptyList("No SiPMs associated to this peak")
        try:
            E = self.s2sid[peak_number][sipm_number]
            t = self.peak_waveform(peak_number).t

            for i in range(len(E)):
                if E[i] > 0:
                    TZS.append(t[i])
                    EZS.append(E[i])
            tzs = np.array(TZS)
            Ezs = np.array(EZS)

            return Peak(np.asarray(tzs), np.asarray(Ezs))
        except KeyError:
            raise SipmNotFound

    cpdef sipm_total_energy(self, int peak_number, int sipm_number):
        """For peak and and sipm_number return Q, where Q is the SiPM total energy."""
        cdef double et
        if self.number_of_sipms_in_peak(peak_number) == 0:
            return 0
        try:
            et = np.sum(self.s2sid[peak_number][sipm_number])
            return et
        except KeyError:
            raise SipmNotFound

    cpdef sipm_total_energy_dict(self, int peak_number):
        """For peak number return {sipm: Q}. """
        cdef dict Q_sipm_dict = {}
        if self.number_of_sipms_in_peak(peak_number) == 0:
            return Q_sipm_dict
        for sipm_number in self.sipms_in_peak(peak_number):
            Q_sipm_dict[sipm_number] = self.sipm_total_energy( peak_number, sipm_number)
        return Q_sipm_dict

    cpdef peak_and_sipm_total_energy_dict(self):
        """Return {peak_no: sipm: Q}."""
        cdef dict Q_dict = {}
        for peak_number in self.peak_collection():
            Q_dict[peak_number] = self.sipm_total_energy_dict(peak_number)

        return Q_dict

    cpdef store(self, table, event_number):
        row = table.row
        for peak, sipm in self.s2sid.items():
            for nsipm, ene in sipm.items():
                for E in ene:
                    row["event"]   = event_number
                    row["peak"]    = peak
                    row["nsipm"]   = nsipm
                    row["ene"]     = E
                    row.append()

    def __str__(self):
        s  = "=" * 80 + "\n" + S2.__str__(self)

        s += "-" * 80 + "\nSiPMs for non-empty peaks\n\n"

        s2a = ["peak number = {}: nsipm in peak = {}"
               .format(peak_number, self.sipms_in_peak(peak_number))
               for peak_number in self.peaks
               if len(self.sipms_in_peak(peak_number)) > 0]

        s += '\n\n'.join(s2a) + "\n"

        s += "-" * 80 + "\nSiPMs Waveforms\n\n"

        s2b = ["peak number = {}: sipm number = {}\n    sipm waveform (zs) = {}".format(peak_number, sipm_number, self.sipm_waveform_zs(peak_number, sipm_number))
               for peak_number in self.peaks
               for sipm_number in self.sipms_in_peak(peak_number)
               if len(self.sipms_in_peak(peak_number)) > 0]

        return s + '\n'.join(s2b) + "\n" + "=" * 80

    def __repr__(self):
        return self.__str__()


cdef class S12Pmt(S12):
    """
    A pmt S12 class for storing individual pmt s12 responses.

    It is analagous to S2Si with the caveat that each peak key in pmtsd maps to a nparray of
    pmt energies instead of another dictionary. Here a dictionary mapping pmt_number --> energy is
    superfluous since the csum of all active pmts are used to calculate the s12 energy.
    """
    def __init__(self, s12d, pmtsd):
        """where:
        s12d  = { peak_number: [[t], [E]]}
        pmtsd = { peak_number: [[Epmt0], [Epmt1], ... ,[EpmtN]] }
        """
        # Check that energies in s12d are sum of pmtsd across pmts for each peak
        for peak, s12_pmts in zip(s12d.values(), pmtsd.values()):
            if not np.allclose(peak[1], s12_pmts.sum(axis=0)):
                raise InconsistentS12dPmtsd

        S12.__init__(self, s12d)
        self.pmtsd = pmtsd

    cpdef pmt_waveform(self, int peak_number, int pmt_number):
        cdef double [:] E
        if peak_number not in self.pmtsd:
            raise PeakNotFound
        else:
          E = self.pmtsd[peak_number][pmt_number]
          return Peak(self.peak_waveform(peak_number).t, np.asarray(E))

    cpdef pmt_total_energy_in_peak(self, int peak_number, int pmt_number):
        """
        For peak_number and and pmt_number return the integrated energy in that pmt in that peak
        pmtsd[peak_number][pmt_number].sum().
        """
        cdef double et
        try:
            et = np.sum(self.pmtsd[peak_number][pmt_number])
            return et
        except KeyError:
            raise PeakNotFound

    cpdef pmt_total_energy(self, int pmt_number):
        """
        For peak_number and and pmt_number return the integrated energy in that pmt in that peak
        pmtsd[peak_number][pmt_number].sum().
        """
        cdef double sum
        cdef int pn
        sum = 0
        for pn in self.pmtsd:
            sum += self.pmt_total_energy_in_peak(pn, pmt_number)
        return sum


    cpdef store(self, table, event_number):
        row = table.row
        for peak, s12_pmts in self.pmtsd.items():
            for npmt, s12_pmt in enumerate(s12_pmt):
                for E in s12_pmt:
                    row["event"]   = event_number
                    row["peak"]    = peak
                    row["nsipm"]   = npmt
                    row["ene"]     = E
                    row.append()


cdef class S1Pmt(S12Pmt):
    def __init__(self, s1d, pmtsd):
        self.s1d = s1d
        S12Pmt.__init__(self, s1d, pmtsd)


cdef class S2Pmt(S12Pmt):
    def __init__(self, s2d, pmtsd):
        self.s2d = s2d
        S12Pmt.__init__(self, s2d, pmtsd)