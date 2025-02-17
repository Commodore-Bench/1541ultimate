library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity slot_timing is
port (
    clock           : in  std_logic;
    reset           : in  std_logic;
    
    -- Cartridge pins -- Already synchronized!
    PHI2            : in  std_logic;
    BA              : in  std_logic;

    serve_vic       : in  std_logic;
    serve_enable    : in  std_logic;
    serve_inhibit   : in  std_logic;

    timing_addr     : in  unsigned(2 downto 0) := "000";
    edge_recover    : in  std_logic;
    
    allow_serve     : out std_logic;

    phi2_tick       : out std_logic;
    phi2_fall       : out std_logic;
    phi2_recovered  : out std_logic;
    clock_det       : out std_logic;
    vic_cycle       : out std_logic;    

    refr_inhibit    : out std_logic;
    reqs_inhibit    : out std_logic;
    clear_inhibit   : in  std_logic;
    
    do_sample_addr  : out std_logic;
    do_probe_end    : out std_logic;
    do_sample_io    : out std_logic;
    do_io_event     : out std_logic );
end slot_timing;

architecture gideon of slot_timing is
    signal phi2_d       : std_logic;
    signal phase_h      : integer range 0 to 63 := 0;
    signal phase_l      : integer range 0 to 63 := 0;
    signal allow_tick_h : boolean := true;
    signal allow_tick_l : boolean := true;
    signal phi2_falling : std_logic;
    signal ba_hist      : std_logic_vector(3 downto 0) := (others => '0');
    signal phi2_rec_i   : std_logic := '0';
    
    signal phi2_tick_i  : std_logic;
    signal serve_en_i   : std_logic := '0';
    signal vic_cycle_i  : std_logic := '0';
    signal off_cnt      : integer range 0 to 7;
    constant c_memdelay    : integer := 6;
    constant c_probe_end   : integer := 14; -- 300 ns after PHI2
    constant c_sample_vic  : integer := 9; -- 200 ns after PHI2 (!)
    constant c_io          : integer := 15;
begin
    vic_cycle_i    <= '1' when (ba_hist = "0000") else '0';
    vic_cycle      <= vic_cycle_i;
    phi2_recovered <= phi2_rec_i;
    phi2_tick      <= phi2_tick_i;
    phi2_fall      <= phi2_d and not PHI2;
    
    process(clock)
    begin
        if rising_edge(clock) then
            phi2_d      <= PHI2;
            phi2_tick_i <= '0';
            
            -- Off counter, to allow software to gracefully quit
            if serve_enable='1' and serve_inhibit='0' then
                off_cnt <= 7;
                serve_en_i <= '1';
            elsif off_cnt = 0 then
                serve_en_i <= '0';
            elsif phi2_tick_i='1' and BA='1' then
                off_cnt <= off_cnt - 1;
                serve_en_i <= '1';
            end if;

            -- detect or create rising edge
            if ((edge_recover = '1') and (phase_l = 24)) or 
               ((edge_recover = '0') and phi2_d='0' and PHI2='1' and allow_tick_h) then
                ba_hist      <= ba_hist(2 downto 0) & BA;
                phi2_tick_i  <= '1';
                phi2_rec_i   <= '1';
                phase_h      <= 0;
                reqs_inhibit <= serve_en_i;
                clock_det    <= '1';
                allow_tick_h <= false; -- filter
            elsif phase_h = 63 then
                clock_det <= '0';
                refr_inhibit <= '0';
            else                            
                phase_h <= phase_h + 1;
            end if;
            if phase_h = 42 then -- max 1.16 MHz
                allow_tick_h <= true;
            end if;

            -- related to falling edge
            phi2_falling <= '0';
            if phi2_d='1' and PHI2='0' and allow_tick_l then  -- falling edge
                phi2_falling <= '1';
                phi2_rec_i   <= '0';
                phase_l      <= 0;
                allow_tick_l <= false; -- filter
            elsif phase_l /= 63 then
                phase_l <= phase_l + 1;
            end if;
            if phase_l = 42 then -- max 1.16 MHz
                allow_tick_l <= true;
            end if;

            do_io_event <= phi2_falling;

            -- timing pulses
            do_sample_addr <= '0';
            if (vic_cycle_i = '0' and phase_h = timing_addr) or 
               (vic_cycle_i = '1' and phase_h = c_sample_vic - 1) then
                do_sample_addr <= '1';
            end if;

            if phase_l = (c_sample_vic - c_memdelay) then
                reqs_inhibit <= serve_en_i and serve_vic;
            elsif phase_l = (c_sample_vic - 1) then
                do_sample_addr <= '1';            
            end if;

            if clear_inhibit='1' then
                reqs_inhibit <= '0';
            end if;
            
            if phase_l = 20 or phase_h = 20 then
                refr_inhibit <= '1'; -- doesn't matter if serve is on or off, refresh can always be in cadence with PHI2
            elsif clear_inhibit = '1' then
                refr_inhibit <= '0';
            end if;   

            do_probe_end <= '0';            
            if phase_h = c_probe_end then
                do_probe_end <= '1';
            end if;

            do_sample_io <= '0';
            if phase_h = c_io - 1 then
                do_sample_io <= '1';
            end if;

            if reset='1' then
                allow_tick_h <= true;
                allow_tick_l <= true;
                phase_h      <= 63;
                phase_l      <= 63;
                refr_inhibit <= '0';
                reqs_inhibit <= '0';
                clock_det    <= '0';
            end if;
        end if;
    end process;
    
    allow_serve <= serve_en_i;
end gideon;
