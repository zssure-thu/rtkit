module RTKIT

  # Contains the DICOM data and methods related to a binary image.
  #
  # === Inheritance
  #
  # * As the BinImage class inherits from the Image class, all Image methods are available to instances of BinImage.
  #
  class BinImage < Image

    # The BinImage's Image reference.
    attr_reader :image
    # The binary numerical image array.
    attr_reader :narray
    # A narray containing pixel indices.
    attr_reader :narray_indices

    # Creates a new BinImage instance from an array of contours.
    # The BinImage is typically defined from a ROI delineation against an image
    # instance from a CT/MR image series, but it may also be applied to an
    # rtdose 'image' series.
    #
    # @param [Array<Contour>] contours the contours from which to derive the binary image
    # @param [SliceImage] image the image slice which this binary image is related to (derived from)
    # @param [BinVolume] bin_volume the binary volume which this binary image belongs to
    # @return [BinImage] the created BinImage instance
    #
    def self.from_contours(contours, image, bin_volume)
      raise ArgumentError, "Invalid argument 'contours'. Expected Array, got #{contours.class}." unless contours.is_a?(Array)
      raise ArgumentError, "Invalid argument 'image'. Expected SliceImage, got #{image.class}." unless image.is_a?(SliceImage)
      raise ArgumentError, "Invalid argument 'bin_volume'. Expected BinVolume, got #{bin_volume.class}." unless bin_volume.is_a?(BinVolume)
      # Create the narray to be used:
      narr = NArray.byte(image.columns, image.rows)
      # Create the BinImage instance:
      bi = self.new(narr, image)
      # Delineate and fill for each contour:
      contours.each do |contour|
        x, y, z = contour.coords
        bi.add(image.binary_image(x, y, z))
      end
      bin_volume.add(bi)
      return bi
    end

    # Creates a new BinImage instance.
    #
    # @param [NArray] narray a binary two-dimensional array
    # @param [SliceImage] image the image slice which this binary image is associated with
    #
    def initialize(narray, image)
      raise ArgumentError, "Invalid argument 'narray'. Expected NArray, got #{narray.class}." unless narray.is_a?(NArray)
      raise ArgumentError, "Invalid argument 'image'. Expected Image, got #{image.class}." unless image.is_a?(Image)
      raise ArgumentError, "Invalid argument 'narray'. Expected two-dimensional NArray, got #{narray.shape.length} dimensions." unless narray.shape.length == 2
      raise ArgumentError, "Invalid argument 'narray'. Expected NArray of element size 1 byte, got #{narray.element_size} bytes (per element)." unless narray.element_size == 1
      raise ArgumentError, "Invalid argument 'narray'. Expected binary NArray with max value 1, got #{narray.max} as max." if narray.max > 1
      self.narray = narray
      @image = image
    end

    # Checks for equality.
    #
    # Other and self are considered equivalent if they are
    # of compatible types and their attributes are equivalent.
    #
    # @param other an object to be compared with self.
    # @return [Boolean] true if self and other are considered equivalent
    #
    def ==(other)
      if other.respond_to?(:to_bin_image)
        other.send(:state) == state
      end
    end

    alias_method :eql?, :==

    # Adds a binary image array to the image array of this instance. This is
    # achieved by adding the segmented pixels of the new array (pixels with
    # value = 1) to the instance array (which may or may not already contain
    # segmented pixels).
    #
    # @param [NArray] pixels a binary two-dimensional array
    #
    def add(pixels)
      raise ArgumentError, "Invalid argument 'pixels'. Expected NArray, got #{pixels.class}." unless pixels.is_a?(NArray)
      raise ArgumentError, "Invalid argument 'pixels'. Expected NArray of element size 1 byte, got #{pixels.element_size} bytes (per element)." unless pixels.element_size == 1
      raise ArgumentError, "Invalid argument 'pixels'. Expected binary NArray with max value 1, got #{pixels.max} as max." if pixels.max > 1
      raise ArgumentError, "Invalid argument 'pixels'. Expected NArray to have same dimension as the instance array. Got #{pixels.shape}, expected #{@narray.shape}." unless pixels.shape == @narray.shape
      @narray[(pixels > 0).where] = 1
    end

    # Calculates the area defined by true/false (i.e. 1/0) pixels.
    # By default, the area of the 'true' pixels are returned.
    #
    # @param [Boolean] type pixel type of interest (i.e. the 'true' or 'false' pixels)
    # @return [Float] the calculated area (in units of millimeters squared)
    #
    def area(type=true)
      if type
        number = (@narray.eq 1).where.length
      else
        number = (@narray.eq 0).where.length
      end
      # Total area is number of pixels times the area per pixel:
      return number * @image.pixel_area
    end

    # Gives the col_spacing attribute of the associated image.
    #
    # @return [Float] the distance between columns in the pixel data (in units of millimeters)
    #
    def col_spacing
      return @image.col_spacing
    end

    # Gives the the number of columns in the binary array.
    #
    # @return [Integer] the number of columns in the binary array
    #
    def columns
      return @narray.shape[0]
    end

    # Applies the contour indices of this instance to an empty image
    # (two-dimensional NArray) to create a 'contour image'.
    # Each separate contour is indicated by individual integers (e.g. 1,2,3 etc).
    #
    # @return [NArray] a contoured numerical array
    #
    def contour_image
      img = NArray.byte(columns, rows)
      contour_indices.each_with_index do |contour, i|
        img[contour.indices] = i + 1
      end
      return img
    end

    # Extracts the contour indices of the (filled) structures contained in the
    # BinImage, by performing a contour tracing algorithm on the binary image.
    #
    # @see The contours are established using a contour tracing algorithm called "Radial Sweep":
    #   http://www.imageprocessingplace.com/downloads_V3/root_downloads/tutorials/contour_tracing_Abeer_George_Ghuneim/ray.html
    #
    # @note Does not detect inner contour of hollow structures (holes).
    # @return [Array<Selection>] an array filled with contour Selection instances (the length of the array equals the number of separate structures in the image)
    #
    def contour_indices
      # Create the array to be returned:
      contours = Array.new
      # Initialize the contour extraction process if indicated:
      if @narray.segmented?
        # Initialize some variables used by the contour algorithm:
        initialize_contour_reorder_structures unless @reorder
        # The contour algorithm needs the image to be padded with a border of zero-pixels:
        original_image = @narray
        padded_image = NArray.byte(columns + 2, rows + 2)
        padded_image[1..-2, 1..-2] = @narray
        # Temporarily replace our instance image with the padded image:
        self.narray = padded_image
        # Get the contours:
        padded_contours = extract_contours
        # Convert from padded indices to proper indices:
        padded_contours.each do |padded_contour|
          padded_contour.shift_and_crop(-1, -1)
          contours << padded_contour
        end
        # Restore the instance image:
        self.narray = original_image
      end
      return contours
    end

    # Gives the cosines attribute of the associated image.
    #
    # @return [Array] the 6 directional cosines of the pixel data
    #
    def cosines
      return @image.cosines
    end

    # Computes a hash code for this object.
    #
    # @note Two objects with the same attributes will have the same hash code.
    #
    # @return [Fixnum] the object's hash code
    #
    def hash
      state.hash
    end

    # Gives the indices of either the true or the false pixels of the binary image.
    #
    # @param [Boolean] state the state of the pixels for which to extract indices (defaults to true)
    # @return [Array] the indices of the true or false pixels in the binary image
    #
    def indices(state=true)
      if state
        (@narray.eq 1).where.to_a
      else
        (@narray.eq 0).where.to_a
      end
    end

    # Sets a new binary array for this BinImage instance.
    #
    # @param [NArray] image a binary two-dimensional array
    #
    def narray=(image)
      raise ArgumentError, "Invalid argument 'image'. Expected NArray, got #{image.class}." unless image.is_a?(NArray)
      raise ArgumentError, "Invalid argument 'image'. Expected two-dimensional NArray, got #{image.shape.length} dimensions." unless image.shape.length == 2
      raise ArgumentError, "Invalid argument 'image'. Expected NArray of element size 1 byte, got #{image.element_size} bytes (per element)." unless image.element_size == 1
      raise ArgumentError, "Invalid argument 'image'. Expected binary NArray with max value 1, got #{image.max} as max." if image.max > 1
      @narray = image
      # Create a corresponding array of the image indices (used in image processing):
      @narray_indices = NArray.int(columns, rows).indgen!
    end

    # Gives the pos_slice attribute from the Image reference.
    #
    # @return [Float, NilClass] the slice position of the associated image (in units of millimeters)
    #
    def pos_slice
      return @image ? @image.pos_slice : nil
    end

    # Gives the pos_x attribute of the associated image.
    #
    # @return [Float] the x coordinate of the upper left hand corner of the image (in units of millimeters)
    #
    def pos_x
      return @image.pos_x
    end

    # Gives the pos_y attribute of the associated image.
    #
    # @return [Float] the y coordinate of the upper left hand corner of the image (in units of millimeters)
    #
    def pos_y
      return @image.pos_y
    end

    # Gives the row_spacing attribute of the associated image.
    #
    # @return [Float] the distance between pixel rows (i.e. vertical spacing) (in units of millimeters)
    #
    def row_spacing
      return @image.row_spacing
    end

    # Gives the the number of rows in the binary array.
    #
    # @return [Integer] the number of rows in the binary array
    #
    def rows
      return @narray.shape[1]
    end

    # Creates a Selection containing all 'true' (segmented) indices of this
    # instance, i.e. indices of all pixels with a value of 1.
    #
    # @return [Selection] the indices of the 'true' pixels of this binary image
    #
    def selection
      s = Selection.new(self)
      s.add_indices((@narray.eq 1).where)
      return s
    end

    # Returns self.
    #
    # @return [BinImage] self
    #
    def to_bin_image
      self
    end

    # Converts the BinImage instance to a single image BinVolume instance.
    #
    # @param [ImageSeries, DoseVolume] series an image series which forms the reference data of the BinVolume
    # @param [ROI, RTDose] source the object which is the source of the binary (segmented) data (i.e. ROI or dose/hounsfield threshold)
    # @return [BinVolume] a binary volume containing a single binary image
    #
    def to_bin_volume(series, source=nil)
      bin_volume = BinVolume.new(series, :images => [self], :source => source)
    end

    # Creates an array of Contour instances from the segmentation of this BinImage.
    #
    # @param [Slice] slice the Slice instance which the created contours will be associated with
    # @return [Array<Contour>] an array of contour instances (or an empty array if no contours are created)
    #
    def to_contours(slice)
      raise ArgumentError, "Invalid argument 'slice. Expected Slice, got #{slice.class}." unless slice.is_a?(Slice)
      contours = Array.new
      # Iterate the extracted collection of contour indices and convert to Contour instances:
      contour_indices.each do |contour|
        # Convert column and row indices to X, Y and Z coordinates:
        x, y, z = coordinates_from_indices(NArray.to_na(contour.columns), NArray.to_na(contour.rows))
        # Convert NArray to Array and round the coordinate floats:
        x = x.to_a.collect {|f| f.round(1)}
        y = y.to_a.collect {|f| f.round(1)}
        z = z.to_a.collect {|f| f.round(3)}
        contours << Contour.create_from_coordinates(x, y, z, slice)
      end
      return contours
    end

    # Creates a DICOM object from the BinImage instance. This is achieved by
    # copying the elements of the DICOM object of the Image instance
    # referenced by this BinImage, and replacing its pixel data with the
    # NArray of this instance.
    #
    # @return [DICOM::DObject] the created DICOM object
    #
    def to_dcm
      # Use the original DICOM object as a starting point (keeping all non-sequence elements):
      # Note: Something like dcm.dup doesn't work here because that only performs a shallow copy on the DObject instance.
      dcm = DICOM::DObject.new
      @image.dcm.each_element do |element|
        # A bit of a hack to regenerate the DICOM elements:
        begin
          if element.value
            # ATM this fails for tags with integer values converted to a backslash-separated string:
            DICOM::Element.new(element.tag, element.value, :parent => dcm)
          else
            # Transfer the binary content as long as it is not the pixel data string:
            DICOM::Element.new(element.tag, element.bin, :encoded => true, :parent => dcm)
          end
        rescue
          DICOM::Element.new(element.tag, element.value.split("\\").collect {|val| val.to_i}, :parent => dcm) if element.value
        end
      end
      dcm.delete_group('0002')
      # Format the DICOM image ensure good contrast amongst the binary pixel values:
      # Window Center:
      DICOM::Element.new('0028,1050', '128', :parent => dcm)
      # Window Width:
      DICOM::Element.new('0028,1051', '256', :parent => dcm)
      # Rescale Intercept:
      DICOM::Element.new('0028,1052', '0', :parent => dcm)
      # Rescale Slope:
      DICOM::Element.new('0028,1053', '1', :parent => dcm)
      # Pixel data:
      dcm.pixels = @narray*255
      return dcm
    end

    # Creates a Slice instance from the segmentation of this BinImage.
    #
    # @param [ROI] roi the ROI instance which the created Slice will be associated with
    # @return [Slice] the created slice instance (including contour references if the binary image is segmented)
    #
    def to_slice(roi)
      raise ArgumentError, "Invalid argument 'roi'. Expected ROI, got #{roi.class}." unless roi.is_a?(ROI)
      # Create the Slice:
      s = Slice.new(@image.uid, roi)
      # Create Contours:
      to_contours(s)
      return s
    end


    private


    # Determines a set of pixel indices which enclose the structure.
    #
    # @see This implementation uses Roman Khudeevs algorithm:
    #   A New Flood-Fill Algorithm for Closed Contour.
    #   https://docs.google.com/viewer?a=v&q=cache:UZ6bo7pXRoIJ:file.lw23.com/file1/01611214.pdf+flood+fill+from+contour+coordinate&hl=no&gl=no&pid=bl&srcid=ADGEEShV4gbKYYq8cDagjT7poT677cIL44K0QW8SR0ODanFy-CD1CHEQi2RvHF8MND7_PXPGYRJMJAcMJO-NEXkM-vU4iA2rNljVetbzuARWuHtKLJKMTNjd3vaDWrIeSU4rKLCVwvff&sig=AHIEtbSAnH6fp584c0_Krv298n-tgpNcJw&pli=1
    #
    # @return [Selection] the contour's indices
    #
    def external_contour
      start_index = (@narray > 0).where[0] - 1
      s_col, s_row = indices_general_to_specific(start_index, columns)
      col, row = s_col, s_row
      row_indices = Array.new(1, row)
      col_indices = Array.new(1, col)
      last_dir = :north # on first step, pretend we came from the south (going north)
      directions = {
        :north => {:dir => [:east, :north, :west, :south], :col => [1, 0, -1, 0], :row => [0, -1, 0, 1]},
        :east => {:dir => [:south, :east, :north, :west], :col => [0, 1, 0, -1], :row => [1, 0, -1, 0]},
        :south => {:dir => [:west, :south, :east, :north], :col => [-1, 0, 1, 0], :row => [0, 1, 0, -1]},
        :west => {:dir => [:north, :west, :south, :east], :col => [0, -1, 0, 1], :row => [-1, 0, 1, 0]},
      }
      loop = true
      while loop do
        # Probe the neighbourhood pixels in a CCW order:
        map = directions[last_dir]
        4.times do |i|
          # Find the first 'free' (zero) pixel, and make that index
          # the next pixel of our external contour:
          if @narray[col + map[:col][i], row + map[:row][i]] == 0
            last_dir = map[:dir][i]
            col = col + map[:col][i]
            row = row + map[:row][i]
            col_indices << col
            row_indices << row
            break
          end
        end
        loop = false if col == s_col and row == s_row
      end
      return Selection.create_from_array(indices_specific_to_general(col_indices, row_indices, columns), self)
    end

    # This is a recursive method which extracts a contour, determines all pixels
    # belonging to this contour, removes them from the binary image, then
    # repeats collecting contours until there are no more pixels left.
    #
    # @return [Array<Selection>] an array of indices for all the contours derived from the segmented image
    #
    def extract_contours
      contours = Array.new
      if @narray.segmented?
        # Get contours:
        corners, continuous  = extract_single_contour
        # If we dont get at least 3 indices, there is no area to fill.
        if continuous.indices.length < 3
          # In this case we remove the pixels and do not record the contour indices:
          roi = continuous
        else
          # Record the indices and get all indices of the structure:
          contours << corners
          # Flood fill the image to determine all pixels contained by the contoured structure:
          roi = roi_indices(continuous)
          # A precaution:
          raise "Unexpected result: #{roi.indices.length}. Raising an error to avoid an infinite recursion!" if roi.indices.length < 3
        end
        # Reset the pixels belonging to the contoured structure from the image:
        @narray[roi.indices] = 0
        # Repeat with the 'cleaned' image to get any additional contours present:
        contours += extract_contours
      end
      return contours
    end

    # Gives the contour indices (Selection) from the first (if any) structure
    # found in the binary image of this instance.
    #
    # FIXME: For now, a rather simple corner detection algorithm is integrated and used.
    # At some stage this could be replaced/supplemented with a proper ('lossy') corner detection algorithm.
    #
    # @return [Array<Selection>] an array containing two sets of indices: corner indices as well as all contour indices
    #
    def extract_single_contour
      # Set up an array to keep track of the pixels belonging to the current contour being analyzed by the algorithm:
      current_indices = Array.new
      # Also keep track of the direction we 'arrived from' (in addition to the pixel position):
      contour_directions = Array.new
      # First step of contour algorithm: Identify a border pixel which will be our start pixel.
      # Traditionally this is achieved by scanning the image, row by row, left to right, until a foreground pixel is found.
      # Instead of scanning, this implementation will extract all foreground indices and chose the first index as our start pixel.
      indices = (@narray > 0).where
      if indices.length > 0
        current_indices << indices[0]
        # Generally we will store the direction we came from along with the pixel position - but not for the first pixel.
        # Specific indices for the first pixel:
        p_col, p_row = indices_general_to_specific(current_indices.first, columns)
        # Set up variables for the initial run of the contour algorithm loop:
        arrived_from = :west
        direction_from_corner = nil
        continue = true
        while continue do
          # Radially sweep the 8 pixels surrounding the start pixel, until a foreground pixel is found.
          # We do this by extracting a 3*3 array centered on our position. Based on the direction to the previous pixel,
          # we then extract the neighbour pixels in such a way the pixel where we came from in the previous step is first in our vector.
          local_pixels = @narray[(p_col-1)..(p_col+1), (p_row-1)..(p_row+1)].flatten
          local_indices = @narray_indices[(p_col-1)..(p_col+1), (p_row-1)..(p_row+1)].flatten
          neighbour_pixels = local_pixels[@reorder[arrived_from]]
          neighbour_indices = local_indices[@reorder[arrived_from]]
          neighbour_relative_indices = @relative_indices[@reorder[arrived_from]]
          # The next border pixel is then the first foreground pixel in the extracted vector.
          local_foreground = (neighbour_pixels > 0).where
          if local_foreground.length > 0
            # We identified another border pixel.
            first_foreground_index = local_foreground[0]
            current_pixel_index = neighbour_indices[first_foreground_index]
            # Stopping criterion: If current pixel equals the second pixel, and the previous pixel equals the first pixel,
            # then we can be absolutely sure that we have made a full contour, regardless of the connectivity of the border.
            if current_pixel_index == current_indices[1] and current_indices.last == current_indices.first
              # We have re-located the original start pixels. Remove the duplicate last element and abort the search.
              current_indices.pop
              #contour_directions.pop
              continue = false
            else
              # Extract x and y index as well as the direction we arrived from:
              p_col, p_row = indices_general_to_specific(current_pixel_index, columns)
              arrived_from = @arrived_from_directions[neighbour_relative_indices[first_foreground_index]]
              # Store pixel and continue the search, using the newly identified border pixel in the next step.
              current_indices << current_pixel_index
              contour_directions << arrived_from
            end
          else
            # No foreground pixel was found, search finished.
            continue = false
          end
        end
        # Before reducing to corner indices, make a copy of the full set of indices:
        all_indices = Selection.create_from_array(current_indices, self)
        # We only want corner points: Remove all the indices that are between corner points:
        img_contour_original = current_indices.dup
        current_indices = Array.new(1, img_contour_original.first)
        img_contour_original.delete_at(0)
        original_direction = contour_directions.first
        contour_directions.delete_at(0)
        img_contour_original.each_index do |i|
          if contour_directions[i] != original_direction
            # Store pixel and set new direction:
            current_indices << img_contour_original[i]
            original_direction = contour_directions[i]
          end
        end
        corner_indices = Selection.create_from_array(current_indices, self)
      end
      return corner_indices, all_indices
    end

    # Initializes a couple of instance variables containing directional information, which are used by the contour algorithm.
    #
    # The directional vectors of indices are used for extracting a vector of neighbour pixels from a 3*3 pixel array,
    # where the resulting vector contains 7 neighbour pixels (the previous pixel is removed), in a clockwise order,
    # where the first pixel is the neighbour pixel that is next to the previous pixel, following a clockwise rotation.
    #
    def initialize_contour_reorder_structures
      @reorder = Hash.new
      @reorder[:west] = NArray[0,1,2,5,8,7,6,3]
      @reorder[:nw]    = NArray[1,2,5,8,7,6,3,0]
      @reorder[:north] = NArray[2,5,8,7,6,3,0,1]
      @reorder[:ne]     = NArray[5,8,7,6,3,0,1,2]
      @reorder[:east]  = NArray[8,7,6,3,0,1,2,5]
      @reorder[:se]     = NArray[7,6,3,0,1,2,5,8]
      @reorder[:south] = NArray[6,3,0,1,2,5,8,7]
      @reorder[:sw]     = NArray[3,0,1,2,5,8,7,6]
      @arrived_from_directions = Hash.new
      @arrived_from_directions[0] = :se
      @arrived_from_directions[1] = :south
      @arrived_from_directions[2] = :sw
      @arrived_from_directions[3] = :east
      @arrived_from_directions[5] = :west
      @arrived_from_directions[6] = :ne
      @arrived_from_directions[7] = :north
      @arrived_from_directions[8] = :nw
      # Set up the index of pixels in a neighborhood image extract:
      @relative_indices = NArray.int(3, 3).indgen!
    end

    # Determines all pixel indices which belongs to the specified (continuous) contour indices.
    #
    # This is achieved by applying an external contour (around the original contour),
    # and identifying the indices that are enclosed by this external contour. This identification
    # is carried out by scanning line by line, and marking pixels which lies between two external
    # contour points.
    #
    # * Uses Roman Khudeevs algorithm: A New Flood-Fill Algorithm for Closed Contour
    # * https://docs.google.com/viewer?a=v&q=cache:UZ6bo7pXRoIJ:file.lw23.com/file1/01611214.pdf+flood+fill+from+contour+coordinate&hl=no&gl=no&pid=bl&srcid=ADGEEShV4gbKYYq8cDagjT7poT677cIL44K0QW8SR0ODanFy-CD1CHEQi2RvHF8MND7_PXPGYRJMJAcMJO-NEXkM-vU4iA2rNljVetbzuARWuHtKLJKMTNjd3vaDWrIeSU4rKLCVwvff&sig=AHIEtbSAnH6fp584c0_Krv298n-tgpNcJw&pli=1
    #
    # @param [Selection] contour a set of pixel indices defining a contour
    # @return [Selection] a set of all pixel indices delimited by the given contour
    #
    def roi_indices(contour)
      raise ArgumentError, "Invalid argument 'contour'. Expected Selection, got #{contour.class}." unless contour.is_a?(Selection)
      ext_value = 3
      int_value = 2
      roi_value = 1
      # Determine external contour:
      ext_contour = external_contour
      row_indices = ext_contour.rows
      # Apply the two contours to an image:
      img = NArray.byte(columns, rows)
      img[ext_contour.indices] = ext_value
      img[contour.indices] = int_value
      # Iterate row by row where the contour is defined:
      (row_indices.min..row_indices.max).each do |row_index|
        img_vector = img[true, row_index]
        row_ext_indices = (img_vector.gt 0).where
        # Iterate the column:
        ext_left = nil
        int_found = nil
        (row_ext_indices.min..row_ext_indices.max).each do |col_index|
          if img_vector[col_index] == ext_value and !int_found
            ext_left = col_index
          elsif img_vector[col_index] == int_value
            int_found = true
          elsif img_vector[col_index] == ext_value and int_found
            # We have identified a span of pixels which belong to the internal contour:
            img[(ext_left+1)..(col_index-1), row_index] = roi_value
            # Reset our indicators:
            ext_left = col_index
            int_found = nil
          end
        end
      end
      # Extract and return our roi indices:
      return Selection.create_from_array((img.eq roi_value).where.to_a, self)
    end

    # Collects the attributes of this instance.
    #
    # @return [Array] an array of attributes
    #
    def state
       [@narray]
    end

  end
end