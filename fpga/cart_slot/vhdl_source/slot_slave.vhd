library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.slot_bus_pkg.all;

entity slot_slave is
generic (
    g_big_endian    : boolean );
port (
    clock           : in  std_logic;
    reset           : in  std_logic;

    -- Cartridge pins (ALL SYNCHRONIZED EXTERNALLY!)
    VCC             : in  std_logic;
    RSTn            : in  std_logic;
    PHI2            : in  std_logic;
    IO1n            : in  std_logic;
    IO2n            : in  std_logic;
    ROMLn           : in  std_logic;
    ROMHn           : in  std_logic;
    BA              : in  std_logic;
    GAMEn           : in  std_logic;
    EXROMn          : in  std_logic;
    RWn             : in  std_logic;
    ADDRESS         : in  unsigned(15 downto 0);
    DATA_in         : in  std_logic_vector(7 downto 0);
    DATA_out        : out std_logic_vector(7 downto 0) := (others => '0');
    DATA_tri        : out std_logic;

    -- interface with memory controller
    mem_req         : out std_logic; -- our memory request to serve slot
    mem_rwn         : out std_logic;
    mem_rack        : in  std_logic;
    mem_dack        : in  std_logic;
    mem_rdata       : in  std_logic_vector(31 downto 0);
    mem_wdata       : out std_logic_vector(31 downto 0);
    -- mem_addr comes from cartridge logic

    reset_out       : out std_logic;

    -- timing inputs
    phi2_tick       : in  std_logic;
    do_sample_addr  : in  std_logic;
    do_probe_end    : in  std_logic;
    do_sample_io    : in  std_logic;
    do_io_event     : in  std_logic;
    dma_active_n    : in  std_logic := '1';
    
    -- interface with freezer (cartridge) logic
    allow_serve     : in  std_logic := '0'; -- from timing unit (modified version of serve_enable)
    serve_128       : in  std_logic := '0';
    serve_rom       : in  std_logic := '0'; -- ROML or ROMH
    serve_io1       : in  std_logic := '0'; -- IO1n
    serve_io2       : in  std_logic := '0'; -- IO2n
    allow_write     : in  std_logic := '0';
    kernal_enable   : in  std_logic := '0';
    kernal_probe    : out std_logic := '0';
    kernal_area     : out std_logic := '0';
    force_ultimax   : out std_logic := '0';
    clear_inhibit   : out std_logic := '0';

    epyx_timeout    : out std_logic; -- '0' => epyx is on, '1' epyx is off    
    cpu_write       : out std_logic; -- for freezer

    slot_req        : out t_slot_req;
    slot_resp       : in  t_slot_resp;

    -- interface with hardware
    BUFFER_ENn      : out std_logic );

end slot_slave;    

architecture gideon of slot_slave is
    signal dav          : std_logic := '0';
    signal addr_is_io   : boolean;
    signal addr_is_kernal : std_logic;
    signal mem_req_ff   : std_logic;
    signal mem_rwn_i    : std_logic;
    signal servicable   : std_logic;
    signal io_read_cond : std_logic;
    signal io_write_cond: std_logic;
    signal late_write_cond  : std_logic;
    signal ultimax      : std_logic;
    signal ultimax_d    : std_logic := '0';
    signal ultimax_d2   : std_logic := '0';
    signal mem_wdata_i  : std_logic_vector(7 downto 0);
    signal kernal_probe_i   : std_logic;
    signal kernal_area_i    : std_logic;
    signal kernal_ready     : std_logic;
    signal kernal_read      : std_logic;
    signal mem_data_0       : std_logic_vector(7 downto 0) := X"00";
    signal mem_data_1       : std_logic_vector(7 downto 0) := X"00";
    signal data_mux         : std_logic;

    type   t_state is (idle, mem_access, wait_end);
                       
    signal state     : t_state;
    
    signal epyx_timer       : natural range 0 to 511;
    signal epyx_reset       : std_logic := '0';
begin
    slot_req.io_write      <= do_io_event and io_write_cond;
    slot_req.io_read       <= do_io_event and io_read_cond;
    slot_req.late_write    <= do_io_event and late_write_cond;
    -- TODO: Do we still need io_read_early? If so, should we not check for PHI2 here? Or will we serve I/O data to the VIC?
    slot_req.io_read_early <= '1' when (addr_is_io and RWn='1' and do_sample_addr='1') else '0';
    slot_req.sample_io     <= do_sample_io;

    kernal_area_i <= kernal_enable and not ultimax and addr_is_kernal and PHI2 and (BA or not RWn);

    ultimax <= not GAMEn and EXROMn;
    process(clock)
    begin
        if rising_edge(clock) then
            reset_out <= reset or (not RSTn and VCC);
            ultimax_d <= ultimax;
            ultimax_d2 <= ultimax_d;
            
            -- 470 nF / 3.3K pup / Vih = 2V, but might be lower
            -- Voh buffer = 0.3V, so let's take a threshold of 1.2V => 400 cycles
            -- Now implemented: 512
            if epyx_reset='1' then
                epyx_timer <= 511;
                epyx_timeout <= '0';
            elsif phi2_tick='1' and dma_active_n = '1' then
                if epyx_timer = 0 then
                    epyx_timeout <= '1';
                else
                    epyx_timer <= epyx_timer - 1;
                end if;
            end if;

            slot_req.bus_write <= '0';
            if do_sample_io='1' then
                cpu_write  <= not RWn;

                slot_req.bus_write  <= not RWn;
                slot_req.io_address <= ADDRESS;
                mem_wdata_i         <= DATA_in;

                late_write_cond <= not RWn;
                io_write_cond <= not RWn and (not IO2n or not IO1n);
                io_read_cond  <=     RWn and (not IO2n or not IO1n);
                epyx_reset    <= not IO1n or not ROMLn or not RSTn;
            end if;

            if do_probe_end='1' then
                data_mux <= kernal_probe_i and not ROMHn;
                force_ultimax <= kernal_probe_i;
                kernal_ready <= '1';
                kernal_probe_i <= '0';
            elsif do_io_event='1' then
                force_ultimax <= '0';
                kernal_ready <= '0';
                kernal_read <= '0';
            end if;
            
            clear_inhibit <= '0';
            case state is

            when idle =>
                if do_sample_addr='1' and RWn = '1' then -- early read
                    if allow_serve='1' and servicable='1' then
                        -- memory read
                        clear_inhibit <= '1';
                        mem_req_ff <= '1';
                        mem_rwn_i  <= '1';
                        state      <= mem_access;
                        kernal_probe_i <= kernal_area_i;
                        kernal_read <= kernal_area_i;
                        kernal_ready <= '0';
                    else
                        -- no memory read needed
                        clear_inhibit <= '1';
                    end if;

                elsif do_sample_io='1' then
                    -- last moment to clear the inhibit, always regardless whether we do an access or not
                    clear_inhibit <= '1';
                    if RWn = '0' then -- Memory write?
                        if addr_is_io and allow_write='1' then -- cartridge allows writing to I/O mapped memory
                            if IO1n='0' or IO2n='0' then -- check if I/O selects are asserted
                                mem_req_ff <= '1';
                                mem_rwn_i  <= '0';
                                state <= mem_access;
                            end if;                                
                        elsif allow_write='1' or kernal_area_i='1' then -- not I/O area
                            -- memory write
                            mem_req_ff <= '1';
                            mem_rwn_i  <= '0';
                            state      <= mem_access;
                        end if;
                    end if;
                end if;
                            
            when mem_access =>
                if mem_rack='1' then
                    mem_req_ff <= '0'; -- clear request
                    if mem_rwn_i='0' then  -- if write, we're done.
                        state <= idle;
                    else -- if read, then we need to wait for the data
                        state <= wait_end;
                    end if;
                end if;

            when wait_end =>
                if mem_dack='1' then -- the data is available, register it for putting it on the bus
                    if g_big_endian then
                        mem_data_0 <= mem_rdata(31 downto 24);
                        mem_data_1 <= mem_rdata(23 downto 16);
                    else
                        mem_data_0 <= mem_rdata(7 downto 0);
                        mem_data_1 <= mem_rdata(15 downto 8);
                    end if;
                    dav      <= '1';
                end if;
                if phi2_tick='1' or do_io_event='1' then -- around the clock edges
                    state <= idle;
                    dav    <= '0';
                end if;
                
            when others =>
                null;

            end case;

            if reset='1' then
                data_mux        <= '0';
                dav             <= '0';
                state           <= idle;
                mem_req_ff      <= '0';
                mem_rwn_i       <= '1';
                io_read_cond    <= '0';
                io_write_cond   <= '0';
                late_write_cond <= '0';
                slot_req.io_address <= (others => '0');
                cpu_write       <= '0';
                epyx_reset      <= '1';
                kernal_probe_i  <= '0';
                kernal_read     <= '0';
                kernal_ready    <= '0';
                force_ultimax   <= '0';
            end if;
        end if;
    end process;
    
    -- combinatoric
    addr_is_io <= (ADDRESS(15 downto 9)="1101111"); -- DE/DF
    addr_is_kernal <= '1' when (ADDRESS(15 downto 13)="111") else '0';

    process(RWn, ADDRESS, addr_is_io, ROMLn, ROMHn, serve_128, serve_rom, serve_io1, serve_io2, ultimax, kernal_enable, BA)
    begin
        servicable <= '0';
        if RWn='1' then
            if addr_is_io and (serve_io1='1' or serve_io2='1') then
                servicable <= '1';
            end if;
            if ADDRESS(15)='1' and serve_128='1' then -- 8000-FFFF
                servicable <= '1';
            end if;
            if ADDRESS(15 downto 14)="10" and (serve_rom='1') then -- 8000-BFFF
                servicable <= '1';
            end if;
            if ADDRESS(15 downto 13)="111" and (serve_rom='1') and (ultimax='1') then
                servicable <= '1';
            end if;
            if ADDRESS(15 downto 13)="111" and (kernal_enable='1') and (BA='1') then
                servicable <= '1';
            end if;
        end if;
    end process;

    process(RWn, IO1n, IO2n, ROMLn, ROMHn, kernal_read, kernal_ready, data_mux,
            mem_data_0, mem_data_1, dav, slot_resp, ultimax_d2, serve_io1, serve_io2)
    begin
        DATA_tri <= '0';
        DATA_out <= X"FF";
        if RWn = '1' then -- if current cycle is a read
            if kernal_read='1' then -- we did a kernal fetch; could be mirrored ram or rom
                DATA_tri <= dav and kernal_ready and not ROMHn;-- and ultimax_d2;
                if data_mux = '0' then
                    DATA_out <= mem_data_0;
                else
                    DATA_out <= mem_data_1;
                end if;
                
            elsif IO1n='0' or IO2n='0' then -- IO Reads
                if slot_resp.reg_output = '1' then -- cartridge has something to say (register read)
                    DATA_tri <= '1';
                    DATA_out <= slot_resp.data;
                elsif serve_io1 = '1' and dav = '1' and IO1n = '0' then -- read of I/O1
                    DATA_tri <= '1';
                    DATA_out <= mem_data_0;
                elsif serve_io2 = '1' and dav = '1' and IO2n = '0' then -- read of I/O2
                    DATA_tri <= '1';
                    DATA_out <= mem_data_0;
                end if;
            
            elsif (ROMLn='0' or ROMHn='0') and dav='1' then -- ROM reads
                DATA_tri <= '1';
                DATA_out <= mem_data_0;
            end if;
        end if;
    end process;

    mem_req    <= mem_req_ff;
    mem_rwn    <= mem_rwn_i;
    mem_wdata  <= mem_wdata_i & X"0000" & mem_wdata_i; -- support both little endian as well as big endian
        
    BUFFER_ENn <= '0';

    slot_req.data        <= mem_wdata_i;
    slot_req.bus_address <= ADDRESS;
    slot_req.bus_rwn     <= RWn;

    kernal_probe <= kernal_probe_i;
    kernal_area  <= kernal_area_i;
end gideon;
