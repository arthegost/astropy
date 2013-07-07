from copy import deepcopy

import astropy.units as u
from astropy.units import Quantity
from astropy.coordinates import Angle

from astropy.coordinates.transformations import master_transform_graph
COORD_CLASSES = deepcopy(master_transform_graph._clsaliases)


class SkyCoord(object):
    def __new__(cls, coord, system, in_format=None, out_format=None,
                equinox=None, obstime=None, location=None):

        # Figure out what the input coord looks like
        if isinstance(coord, cls):
            self = coord.copy()  # could be replicate with copy option
            return  # NOT IMPLEMENTED YET REALLY
        else:
            self = super(SkyCoord, cls).__new__(cls)

        if system not in COORD_CLASSES:
            raise ValueError('Coordinate system {0} not in allowed values {1}'
                             .format(system, sorted(COORD_CLASSES)))
        CoordClass = COORD_CLASSES[system]

        self.system = system
        self.in_format = in_format
        self.out_format = out_format
        self.equinox = equinox
        self.obstime = obstime
        self.location = location

        if isinstance(coord, (tuple, list)):
            if len(coord) != 2:
                raise ValueError('Input coord tuple or list must have two elements')
            lon, lat = coord
            if isinstance(lon, (Quantity, Angle)):
                lon = lon.degree
            if isinstance(lat, (Quantity, Angle)):
                lat = lat.degree
            self._coord = CoordClass(lon, lat, unit=(u.degree, u.degree))
        else:
            raise NotImplementedError('Not yet')

        return self

    def transform_to(self, system):
        """
        Transform this coordinate to a new system.

        Parameters
        ----------
        system : str
            The system to transform this coordinate into.

        Returns
        -------
        coord
            A new object with this coordinate represented in the `system` system.

        Raises
        ------
        ValueError
            If there is no possible transformation route.
        """
        from astropy.coordinates.errors import ConvertError

        if system not in COORD_CLASSES:
            raise ValueError('Coordinate system {0} not in allowed values {1}'
                             .format(system, sorted(COORD_CLASSES)))

        out = deepcopy(self)
        if system == self.system:
            return out

        out.system = system
        out._coord = self._coord.transform_to(COORD_CLASSES[system])
        if out._coord is None:
            raise ConvertError('Cannot transform from {0} to '
                               '{1}'.format(self.system, system))

        return out

    def __getattr__(self, name):
        """
        Overrides getattr to return coordinates that this can be transformed
        to, based on the alias name in the master transform graph.
        """
        from astropy.coordinates.transformations import master_transform_graph

        if self.system == name:
            return self

        nmsys = master_transform_graph.lookup_name(name)
        if nmsys is not None and self._coord.is_transformable_to(nmsys):
            return self.transform_to(name)
        else:
            msg = "'{0}' object has no attribute '{1}', nor a transform."
            raise AttributeError(msg.format(self.__class__, name))

    def __dir__(self):
        """
        Overriding the builtin `dir` behavior allows us to add the
        transforms available by aliases.  This also allows ipython
        tab-completion to know about the transforms.
        """
        from astropy.coordinates.transformations import master_transform_graph

        # the stuff `dir` normally gives
        dir_items = dir(type(self)) + self.__dict__.keys()

        # determine the aliases that this can be transformed to.
        for alias in master_transform_graph.get_aliases():
            tosys = master_transform_graph.lookup_name(alias)
            if self._coord.is_transformable_to(tosys):
                dir_items.append(alias)

        return sorted(set(dir_items))
